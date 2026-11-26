package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

const maxRequestBytes = 1 << 20

type api struct {
	store      store
	refresh    *refresher
	logins     loginLimiter
	loginSlots chan struct{}
	now        func() time.Time
}

func newAPI(s store, refresh *refresher) *api {
	return &api{store: s, refresh: refresh, loginSlots: make(chan struct{}, 2), now: time.Now}
}

type apiCall func(http.ResponseWriter, *http.Request)

func (a *api) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", a.health)
	mux.HandleFunc("POST /api/login", a.login)
	mux.HandleFunc("POST /api/logout", a.authenticated(a.logout))
	mux.HandleFunc("GET /api/podcasts", a.authenticated(a.podcasts))
	mux.HandleFunc("POST /api/podcasts", a.authenticated(a.subscribe))
	mux.HandleFunc("DELETE /api/podcasts/{id}", a.authenticated(a.unsubscribe))
	mux.HandleFunc("GET /api/podcasts/{id}/episodes", a.authenticated(a.episodes))
	mux.HandleFunc("GET /api/episodes/{id}", a.authenticated(a.episode))
	mux.HandleFunc("GET /api/episodes/{id}/state", a.authenticated(a.episodeState))
	mux.HandleFunc("GET /api/state", a.authenticated(a.state))
	mux.HandleFunc("POST /api/state", a.authenticated(a.updateState))
	mux.HandleFunc("POST /api/refresh", a.authenticated(a.refreshAll))
	mux.HandleFunc("GET /api/opml", a.authenticated(a.exportOPML))
	mux.HandleFunc("POST /api/opml", a.authenticated(a.importOPML))
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		apiError(w, http.StatusNotFound, "not found")
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Body != nil && r.Body != http.NoBody {
			limited := http.MaxBytesReader(w, r.Body, maxRequestBytes)
			defer limited.Close()
			body, err := io.ReadAll(limited)
			var oversized *http.MaxBytesError
			if errors.As(err, &oversized) {
				apiError(w, http.StatusRequestEntityTooLarge, "body exceeds 1 MiB")
				return
			}
			if err != nil {
				apiError(w, http.StatusBadRequest, "could not read request body")
				return
			}
			r.Body = io.NopCloser(bytes.NewReader(body))
		}
		mux.ServeHTTP(w, r)
	})
}

type deviceContextKey struct{}

func (a *api) authenticated(next apiCall) apiCall {
	return func(w http.ResponseWriter, r *http.Request) {
		scheme, token, ok := strings.Cut(r.Header.Get("Authorization"), " ")
		if !ok || !strings.EqualFold(scheme, "Bearer") {
			apiError(w, http.StatusUnauthorized, "valid bearer token required")
			return
		}
		id, err := a.store.deviceID(r.Context(), token)
		if errors.Is(err, pgx.ErrNoRows) {
			apiError(w, http.StatusUnauthorized, "valid bearer token required")
			return
		}
		if err != nil {
			storeError(w, r, err)
			return
		}
		w.Header().Set("Cache-Control", "private, no-cache")
		next(w, r.WithContext(context.WithValue(r.Context(), deviceContextKey{}, id)))
	}
}

func jsonReply(w http.ResponseWriter, r *http.Request, status int, value any) {
	data, err := json.Marshal(value)
	if err != nil {
		storeError(w, r, err)
		return
	}
	writeJSON(w, status, data)
}

func writeJSON(w http.ResponseWriter, status int, data []byte) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write(data)
}

func conditionalJSON(w http.ResponseWriter, r *http.Request, value any) {
	data, err := json.Marshal(value)
	if err != nil {
		storeError(w, r, err)
		return
	}
	tag := fmt.Sprintf("\"%x\"", sha256.Sum256(data))
	if !respondNotModified(w, r, tag) {
		w.Header().Set("ETag", tag)
		writeJSON(w, http.StatusOK, data)
	}
}

func respondNotModified(w http.ResponseWriter, r *http.Request, tag string) bool {
	value := strings.TrimPrefix(tag, "W/")
	for _, field := range r.Header.Values("If-None-Match") {
		for part := range strings.SplitSeq(field, ",") {
			part = strings.TrimSpace(part)
			if part == "*" || strings.TrimPrefix(part, "W/") == value {
				w.Header().Set("ETag", tag)
				w.WriteHeader(http.StatusNotModified)
				return true
			}
		}
	}
	return false
}

func apiError(w http.ResponseWriter, status int, message string) {
	data, _ := json.Marshal(map[string]string{"error": message})
	writeJSON(w, status, data)
}

func storeError(w http.ResponseWriter, r *http.Request, err error) {
	if errors.Is(err, pgx.ErrNoRows) {
		apiError(w, http.StatusNotFound, "not found")
		return
	}
	status := http.StatusInternalServerError
	attrs := []slog.Attr{slog.String("method", r.Method), slog.String("route", r.Pattern), slog.Int("status", status)}
	switch code := databaseSQLState(err); {
	case code != "":
		attrs = append(attrs, slog.String("sqlstate", code))
	case errors.Is(err, context.Canceled):
		attrs = append(attrs, slog.String("reason", "context canceled"))
	case errors.Is(err, context.DeadlineExceeded):
		attrs = append(attrs, slog.String("reason", "context deadline exceeded"))
	}
	slog.LogAttrs(r.Context(), slog.LevelError, "Could not complete request", attrs...)
	apiError(w, status, "internal server error")
}

func decodeJSON(w http.ResponseWriter, r *http.Request, out any) bool {
	decoder := json.NewDecoder(r.Body)
	if err := decoder.Decode(out); err != nil || decoder.Decode(new(any)) != io.EOF {
		apiError(w, http.StatusBadRequest, "invalid JSON body")
		return false
	}
	return true
}

func pathID(w http.ResponseWriter, r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		apiError(w, http.StatusBadRequest, "invalid id")
		return 0, false
	}
	return id, true
}

func (a *api) health(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := a.store.checkSchema(ctx); err != nil {
		apiError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	jsonReply(w, r, http.StatusOK, map[string]string{"status": "ok"})
}

func (a *api) login(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	var input struct {
		Username   string `json:"username"`
		Password   string `json:"password"`
		DeviceName string `json:"device_name"`
	}
	if !decodeJSON(w, r, &input) {
		return
	}
	if strings.TrimSpace(input.DeviceName) == "" || strings.ContainsRune(input.DeviceName, 0) || strings.ContainsRune(input.Username, 0) {
		apiError(w, http.StatusBadRequest, "invalid username or device name")
		return
	}
	select {
	case a.loginSlots <- struct{}{}:
		defer func() { <-a.loginSlots }()
	case <-r.Context().Done():
		return
	default:
		w.Header().Set("Retry-After", "1")
		apiError(w, http.StatusTooManyRequests, "login is busy")
		return
	}
	finish, wait := a.logins.start(r)
	if wait > 0 {
		w.Header().Set("Retry-After", strconv.FormatInt(int64((wait+time.Second-1)/time.Second), 10))
		apiError(w, http.StatusTooManyRequests, "too many login attempts")
		return
	}
	failed := false
	defer func() { finish(failed) }()
	valid, err := a.store.verifyPassword(r.Context(), input.Username, input.Password)
	if err != nil {
		storeError(w, r, err)
		return
	}
	if !valid {
		failed = true
		apiError(w, http.StatusUnauthorized, "wrong credentials")
		return
	}
	revision, err := a.store.currentStateRevision(r.Context())
	if err != nil {
		storeError(w, r, err)
		return
	}
	token, id, err := a.store.createDevice(r.Context(), input.Username, input.DeviceName)
	if err != nil {
		storeError(w, r, err)
		return
	}
	jsonReply(w, r, http.StatusOK, struct {
		Token    string `json:"token"`
		DeviceID int64  `json:"device_id"`
		ServerID string `json:"server_id"`
	}{token, id, revision.ServerID})
}

func (a *api) logout(w http.ResponseWriter, r *http.Request) {
	id := r.Context().Value(deviceContextKey{}).(int64)
	if _, err := a.store.revokeDevice(r.Context(), id); err != nil {
		storeError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *api) podcasts(w http.ResponseWriter, r *http.Request) {
	items, err := a.store.podcasts(r.Context(), false)
	if err != nil {
		storeError(w, r, err)
		return
	}
	conditionalJSON(w, r, items)
}

func (a *api) subscribe(w http.ResponseWriter, r *http.Request) {
	var input struct {
		FeedURL string `json:"feed_url"`
	}
	if !decodeJSON(w, r, &input) {
		return
	}
	p, added, err := a.refresh.subscribe(r.Context(), input.FeedURL)
	var issue feedError
	switch {
	case errors.As(err, &issue):
		apiError(w, http.StatusUnprocessableEntity, issue.Error())
	case err != nil:
		storeError(w, r, err)
	case added:
		jsonReply(w, r, http.StatusCreated, p)
	default:
		jsonReply(w, r, http.StatusOK, p)
	}
}

func (a *api) unsubscribe(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r)
	if !ok {
		return
	}
	if err := a.store.unsubscribe(r.Context(), id); err != nil {
		storeError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *api) episodes(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r)
	if !ok {
		return
	}
	items, err := a.store.episodes(r.Context(), id)
	if err != nil {
		storeError(w, r, err)
		return
	}
	conditionalJSON(w, r, items)
}

func (a *api) episode(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r)
	if !ok {
		return
	}
	detail, err := a.store.episode(r.Context(), id)
	if err != nil {
		storeError(w, r, err)
		return
	}
	jsonReply(w, r, http.StatusOK, detail)
}

func (a *api) episodeState(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r)
	if !ok {
		return
	}
	state, err := a.store.episodeState(r.Context(), id)
	if err != nil {
		storeError(w, r, err)
		return
	}
	jsonReply(w, r, http.StatusOK, map[string]*episodeState{"state": state})
}

func (a *api) state(w http.ResponseWriter, r *http.Request) {
	if len(r.Header.Values("If-None-Match")) > 0 {
		revision, err := a.store.currentStateRevision(r.Context())
		if err != nil {
			storeError(w, r, err)
			return
		}
		if respondNotModified(w, r, revision.etag()) {
			return
		}
	}
	snapshot, err := a.store.state(r.Context())
	if err != nil {
		storeError(w, r, err)
		return
	}
	tag := snapshot.etag()
	if respondNotModified(w, r, tag) {
		return
	}
	w.Header().Set("ETag", tag)
	jsonReply(w, r, http.StatusOK, struct {
		stateSnapshot
		ServerTime timestamp `json:"server_time"`
	}{snapshot, timestamp{a.now()}})
}

func (r stateRevision) etag() string {
	// The server clock changes even when the state representation is otherwise equivalent.
	return fmt.Sprintf(`W/"state-%s-%d"`, r.ServerID, r.version)
}

func (a *api) updateState(w http.ResponseWriter, r *http.Request) {
	var input *struct {
		stateChange
		ServerID *string `json:"server_id"`
	}
	if !decodeJSON(w, r, &input) {
		return
	}
	if input == nil {
		apiError(w, http.StatusBadRequest, "invalid state")
		return
	}
	input.expectedServerID = input.ServerID
	result, err := a.store.updateState(r.Context(), input.stateChange, a.now())
	switch {
	case errors.Is(err, errServerIDChanged):
		jsonReply(w, r, http.StatusConflict, map[string]string{"error": err.Error(), "server_id": result.ServerID})
	case errors.Is(err, errInvalidState):
		apiError(w, http.StatusBadRequest, err.Error())
	case err != nil:
		storeError(w, r, err)
	default:
		jsonReply(w, r, http.StatusOK, result)
	}
}

func (a *api) refreshAll(w http.ResponseWriter, _ *http.Request) {
	select {
	case a.refresh.force <- struct{}{}:
	default:
	}
	w.WriteHeader(http.StatusAccepted)
}

func (a *api) exportOPML(w http.ResponseWriter, r *http.Request) {
	podcasts, err := a.store.podcasts(r.Context(), true)
	if err != nil {
		storeError(w, r, err)
		return
	}
	data, err := exportOPML(podcasts)
	if err != nil {
		storeError(w, r, err)
		return
	}
	w.Header().Set("Content-Type", "text/x-opml; charset=utf-8")
	_, _ = w.Write(data)
}

func (a *api) importOPML(w http.ResponseWriter, r *http.Request) {
	addresses, err := parseOPML(r.Body)
	if err != nil {
		apiError(w, http.StatusBadRequest, err.Error())
		return
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), opmlTimeout)
	defer cancel()
	result, err := a.refresh.importOPML(ctx, addresses)
	if err != nil {
		storeError(w, r, err)
		return
	}
	jsonReply(w, r, http.StatusOK, result)
}
