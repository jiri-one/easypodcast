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
			storeError(w, err)
			return
		}
		w.Header().Set("Cache-Control", "private, no-cache")
		next(w, r.WithContext(context.WithValue(r.Context(), deviceContextKey{}, id)))
	}
}

func jsonReply(w http.ResponseWriter, status int, value any) {
	data, err := json.Marshal(value)
	if err != nil {
		storeError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write(data)
}

func conditionalJSON(w http.ResponseWriter, r *http.Request, value any) {
	data, err := json.Marshal(value)
	if err != nil {
		storeError(w, err)
		return
	}
	tag := fmt.Sprintf("\"%x\"", sha256.Sum256(data))
	w.Header().Set("ETag", tag)
	for _, field := range r.Header.Values("If-None-Match") {
		for part := range strings.SplitSeq(field, ",") {
			part = strings.TrimSpace(part)
			if part == "*" || strings.TrimPrefix(part, "W/") == tag {
				w.WriteHeader(http.StatusNotModified)
				return
			}
		}
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_, _ = w.Write(data)
}

func apiError(w http.ResponseWriter, status int, message string) {
	jsonReply(w, status, map[string]string{"error": message})
}

func storeError(w http.ResponseWriter, err error) {
	if errors.Is(err, pgx.ErrNoRows) {
		apiError(w, http.StatusNotFound, "not found")
		return
	}
	slog.Error("Could not complete request")
	apiError(w, http.StatusInternalServerError, "internal server error")
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
	if err := a.store.db.Ping(ctx); err != nil {
		apiError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	jsonReply(w, http.StatusOK, map[string]string{"status": "ok"})
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
	finish, ok := a.logins.start(r.RemoteAddr)
	if !ok {
		w.Header().Set("Retry-After", "60")
		apiError(w, http.StatusTooManyRequests, "too many login attempts")
		return
	}
	failed := false
	defer func() { finish(failed) }()
	select {
	case a.loginSlots <- struct{}{}:
	case <-r.Context().Done():
		return
	}
	valid, err := a.store.verifyPassword(r.Context(), input.Username, input.Password)
	<-a.loginSlots
	if err != nil {
		storeError(w, err)
		return
	}
	if !valid {
		failed = true
		apiError(w, http.StatusUnauthorized, "wrong credentials")
		return
	}
	token, id, err := a.store.createDevice(r.Context(), input.Username, input.DeviceName)
	if err != nil {
		storeError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, struct {
		Token    string `json:"token"`
		DeviceID int64  `json:"device_id"`
	}{token, id})
}

func (a *api) logout(w http.ResponseWriter, r *http.Request) {
	id := r.Context().Value(deviceContextKey{}).(int64)
	if _, err := a.store.db.Exec(r.Context(), "DELETE FROM devices WHERE id = $1", id); err != nil {
		storeError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *api) podcasts(w http.ResponseWriter, r *http.Request) {
	items, err := a.store.podcasts(r.Context(), false)
	if err != nil {
		storeError(w, err)
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
		storeError(w, err)
	case added:
		jsonReply(w, http.StatusCreated, p)
	default:
		jsonReply(w, http.StatusOK, p)
	}
}

func (a *api) unsubscribe(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r)
	if !ok {
		return
	}
	if err := a.store.unsubscribe(r.Context(), id); err != nil {
		storeError(w, err)
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
		storeError(w, err)
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
		storeError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, detail)
}

func (a *api) episodeState(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r)
	if !ok {
		return
	}
	state, err := a.store.episodeState(r.Context(), id)
	if err != nil {
		storeError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, map[string]*episodeState{"state": state})
}

func (a *api) state(w http.ResponseWriter, r *http.Request) {
	snapshot, err := a.store.state(r.Context())
	if err != nil {
		storeError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, struct {
		stateChange
		ServerTime timestamp `json:"server_time"`
	}{snapshot, timestamp{a.now()}})
}

func (a *api) updateState(w http.ResponseWriter, r *http.Request) {
	var change *stateChange
	if !decodeJSON(w, r, &change) {
		return
	}
	if change == nil {
		apiError(w, http.StatusBadRequest, "invalid state")
		return
	}
	result, err := a.store.updateState(r.Context(), *change, a.now())
	switch {
	case errors.Is(err, errFutureState), errors.Is(err, errInvalidState):
		apiError(w, http.StatusBadRequest, err.Error())
	case err != nil:
		storeError(w, err)
	default:
		jsonReply(w, http.StatusOK, result)
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
		storeError(w, err)
		return
	}
	data, err := exportOPML(podcasts)
	if err != nil {
		storeError(w, err)
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
	result, err := a.refresh.importOPML(r.Context(), addresses)
	if err != nil {
		storeError(w, err)
		return
	}
	jsonReply(w, http.StatusOK, result)
}
