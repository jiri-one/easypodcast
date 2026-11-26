package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestHTTPAPI(t *testing.T) {
	s := integrationStore(t)
	if err := s.setPassword(t.Context(), "listener", "fixture password"); err != nil {
		t.Fatal(err)
	}
	first, changed := fixture(t, "first.xml"), fixture(t, "changed.xml")
	var calls atomic.Int32
	var mode atomic.Int32
	var conditional atomic.Bool
	feeds := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.UserAgent() != "EasyPodcast/test" {
			t.Errorf("wrong User-Agent: %q", r.UserAgent())
		}
		switch r.URL.Path {
		case "/old":
			http.Redirect(w, r, "/feeds/cloudberry.xml", http.StatusMovedPermanently)
		case "/feeds/cloudberry.xml":
			calls.Add(1)
			switch mode.Load() {
			case 0:
				w.Header().Set("ETag", `"first"`)
				w.Header().Set("Last-Modified", "Thu, 26 Nov 2026 09:15:00 GMT")
				if r.Header.Get("If-None-Match") == `"first"` && r.Header.Get("If-Modified-Since") != "" {
					conditional.Store(true)
					w.WriteHeader(http.StatusNotModified)
					return
				}
				_, _ = w.Write(first)
			case 1:
				w.Header().Set("ETag", `"changed"`)
				_, _ = w.Write(changed)
			default:
				w.WriteHeader(http.StatusBadGateway)
			}
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer feeds.Close()

	refresh := newRefresher(s, "EasyPodcast/test", time.Hour)
	a := newAPI(s, refresh)
	now := time.Date(2026, 11, 26, 12, 0, 0, 0, time.UTC)
	a.now = func() time.Time { return now }
	handler := a.routes()
	token := ""
	call := func(method, path, body, etag, addr string, want int) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		if addr != "" {
			req.RemoteAddr = addr
		}
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("If-None-Match", etag)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		if w.Code != want {
			t.Fatalf("%s %s: got %d want %d: %s", method, path, w.Code, want, w.Body.String())
		}
		return w
	}
	if got := call("GET", "/health", "", "", "", 200).Body.String(); got != `{"status":"ok"}` {
		t.Fatal(got)
	}
	call("GET", "/api/podcasts", "", "", "", 401)
	for range 5 {
		call("POST", "/api/login", `{"username":"listener","password":"wrong","device_name":"Test"}`, "", "", 401)
	}
	login := `{"username":"listener","password":"fixture password","device_name":"Test"}`
	call("POST", "/api/login", login, "", "", 429)
	loginReply := call("POST", "/api/login", login, "", "192.0.2.2:46001", 200)
	tokens := response[struct {
		Token string `json:"token"`
		ID    int64  `json:"device_id"`
	}](t, loginReply)
	token = tokens.Token
	if len(token) != 43 || tokens.ID == 0 {
		t.Fatal("invalid login response")
	}

	call("POST", "/api/state", strings.Repeat(" ", maxRequestBytes+1), "", "", 413)
	call("POST", "/api/state", `{}{}`, "", "", 400)
	call("POST", "/api/state", `{"episodes":[{"episode_id":1,"updated_at":"2026-11-26T12:00:00.000Z"}]}`, "", "", 400)
	if got := call("GET", "/api/podcasts", "", "", "", 200).Body.String(); got != "[]" {
		t.Fatal(got)
	}
	emptyState := call("GET", "/api/state", "", "", "", 200).Body.String()
	if emptyState != `{"episodes":[],"queue":null,"server_time":"2026-11-26T12:00:00.000Z"}` {
		t.Fatal(emptyState)
	}
	call("POST", "/api/podcasts", `{"feed_url":"file:///a"}`, "", "", 422)
	input := fmt.Sprintf(`{"feed_url":%q}`, feeds.URL+"/old")
	p := response[podcast](t, call("POST", "/api/podcasts", input, "", "", 201))
	if p.EpisodeCount != 2 || p.FeedURL != feeds.URL+"/feeds/cloudberry.xml" {
		t.Fatal(p)
	}
	call("POST", "/api/podcasts", input, "", "", 200)
	if calls.Load() != 1 {
		t.Fatal("existing subscription triggered a fetch")
	}
	list := call("GET", "/api/podcasts", "", "", "", 200)
	call("GET", "/api/podcasts", "", "W/"+list.Header().Get("ETag"), "", 304)
	podcastPath := fmt.Sprintf("/api/podcasts/%d", p.ID)
	episodePath := podcastPath + "/episodes"
	list = call("GET", episodePath, "", "", "", 200)
	originalTag := list.Header().Get("ETag")
	call("GET", episodePath, "", originalTag, "", 304)
	episodes := response[[]episode](t, list)
	copper, paper := episodes[0], episodes[1]
	copperPath := fmt.Sprintf("/api/episodes/%d", copper.ID)
	detail := response[episodeDetail](t, call("GET", copperPath, "", "", "", 200))
	if detail.GUID != copper.GUID || !strings.Contains(detail.Description, feeds.URL+"/notes") {
		t.Fatal(detail)
	}
	if got := call("GET", copperPath+"/state", "", "", "", 200).Body.String(); got != `{"state":null}` {
		t.Fatal(got)
	}
	call("GET", "/api/episodes/999999/state", "", "", "", 404)
	call("GET", "/api/podcasts/999999/episodes", "", "", "", 404)
	call("GET", "/api/episodes/abc", "", "", "", 400)

	send := func(when time.Time, position int64, status string, ids []int64, code int) *httptest.ResponseRecorder {
		body, err := json.Marshal(stateChange{
			Episodes: []episodeState{{copper.ID, position, status, timestamp{when}}, {999999, 0, "", timestamp{when}}},
			Queue:    &queue{ids, timestamp{when}},
		})
		if err != nil {
			t.Fatal(err)
		}
		return call("POST", "/api/state", string(body), "", "", code)
	}
	at := now.Add(-time.Minute)
	result := response[stateResult](t, send(at, 120000, "", []int64{paper.ID, 999999, copper.ID}, 200))
	if len(result.Episodes) != 1 || result.Episodes[0].PositionMS != 120000 ||
		!slices.Equal(result.Unknown, []int64{999999}) || !slices.Equal(result.Queue.EpisodeIDs, []int64{paper.ID, copper.ID}) {
		t.Fatalf("initial state: %+v", result)
	}
	for _, stale := range []time.Time{at, at.Add(-time.Second)} {
		result = response[stateResult](t, send(stale, 1, "played", []int64{}, 200))
		if result.Episodes[0].PositionMS != 120000 || len(result.Queue.EpisodeIDs) != 2 {
			t.Fatalf("stale state replaced newer state: %+v", result)
		}
	}
	send(now.Add(24*time.Hour+time.Millisecond), 10, "dismissed", []int64{}, 400)
	invalidQueue := fmt.Sprintf(`{"episodes":[{"episode_id":%d,"position_ms":39000,"status":"","updated_at":"2026-11-26T12:00:00.000Z"}],"queue":{"episode_ids":[],"updated_at":"2026-11-28T12:00:00.000Z"}}`, copper.ID)
	call("POST", "/api/state", invalidQueue, "", "", 400)
	snapshot := response[stateChange](t, call("GET", "/api/state", "", "", "", 200))
	if snapshot.Episodes[0].PositionMS != 120000 {
		t.Fatal("invalid queue request applied episode update")
	}
	result = response[stateResult](t, send(now, 60000, "", []int64{copper.ID}, 200))
	if result.Episodes[0].PositionMS != 60000 {
		t.Fatal("newer rewind did not win")
	}
	result = response[stateResult](t, send(now.Add(24*time.Hour), 0, "played", []int64{}, 200))
	if result.Episodes[0].Status != "played" || result.Queue.EpisodeIDs == nil || len(result.Queue.EpisodeIDs) != 0 {
		t.Fatal("newer completion did not win")
	}
	if got := call("GET", copperPath+"/state", "", "", "", 200).Body.String(); !strings.Contains(got, `"status":"played"`) {
		t.Fatal(got)
	}
	list = call("GET", "/api/podcasts", "", "", "", 200)
	if response[[]podcast](t, list)[0].PlayedCount != 1 {
		t.Fatal("wrong played count")
	}

	call("POST", "/api/refresh", "", "", "", 202)
	select {
	case <-refresh.force:
	default:
		t.Fatal("refresh not queued")
	}
	refresh.refreshDue(t.Context(), true)
	if !conditional.Load() {
		t.Fatal("conditional feed request did not reach the publisher")
	}
	call("GET", episodePath, "", originalTag, "", 304)
	mode.Store(1)
	refresh.refreshDue(t.Context(), true)
	list = call("GET", episodePath, "", originalTag, "", 200)
	episodes = response[[]episode](t, list)
	if len(episodes) != 3 || episodes[0].GUID != "cloudberry-silver" || episodes[1].ID != copper.ID ||
		!strings.HasSuffix(episodes[1].EnclosureURL, "copper-remaster.mp3") || episodes[2].ID != paper.ID || !episodes[2].RemovedFromFeed {
		t.Fatalf("refresh reconciliation: %+v", episodes)
	}
	refreshed := response[[]podcast](t, call("GET", "/api/podcasts", "", "", "", 200))[0]
	if refreshed.EpisodesVersion == p.EpisodesVersion || refreshed.PlayedCount != 1 {
		t.Fatalf("refresh podcast: %+v", refreshed)
	}
	refresh.refreshDue(t.Context(), true)
	if same := response[[]podcast](t, call("GET", "/api/podcasts", "", "", "", 200))[0]; same.EpisodesVersion != refreshed.EpisodesVersion {
		t.Fatal("identical feed changed episodes_version")
	}
	mode.Store(2)
	refresh.refreshDue(t.Context(), true)
	failed := response[[]podcast](t, call("GET", "/api/podcasts", "", "", "", 200))[0]
	if failed.LastError == nil || failed.LastSuccessAt == nil || failed.EpisodesVersion != refreshed.EpisodesVersion {
		t.Fatalf("invalid refresh failure state: %+v", failed)
	}
	var backoff time.Duration
	var seconds float64
	err := s.db.QueryRow(t.Context(), "SELECT extract(epoch FROM (next_refresh_at - now())) FROM podcasts WHERE id = $1", p.ID).Scan(&seconds)
	backoff = time.Duration(seconds * float64(time.Second))
	if err != nil || backoff < 107*time.Minute || backoff > 2*time.Hour {
		t.Fatalf("unexpected error backoff %s, %v", backoff, err)
	}

	export := call("GET", "/api/opml", "", "", "", 200)
	urls, err := parseOPML(export.Body)
	if err != nil || !slices.Equal(urls, []string{p.FeedURL}) {
		t.Fatalf("OPML export: %v, %v", urls, err)
	}
	call("DELETE", podcastPath, "", "", "", 204)
	preserved := response[[]podcast](t, call("GET", "/api/podcasts", "", "", "", 200))
	if len(preserved) != 1 || preserved[0].Subscribed {
		t.Fatal("unsubscribed podcast with state was lost")
	}
	opml := fmt.Sprintf(`<opml><body><outline text="Fiction"><outline xmlUrl="%s"/><outline xmlUrl="broken"/></outline></body></opml>`, p.FeedURL)
	imported := response[opmlResult](t, call("POST", "/api/opml", opml, "", "", 200))
	if imported.Existing != 1 || imported.Added != 0 || len(imported.Failed) != 1 {
		t.Fatalf("OPML import: %+v", imported)
	}
	call("POST", "/api/opml", "<wrong/>", "", "", 400)
	call("POST", "/api/logout", "", "", "", 204)
	call("GET", "/api/state", "", "", "", 401)
	s.db.Close()
	call("GET", "/health", "", "", "", 503)
}

func response[T any](t *testing.T, w *httptest.ResponseRecorder) T {
	t.Helper()
	var value T
	if err := json.Unmarshal(w.Body.Bytes(), &value); err != nil {
		t.Fatalf("response %s: %v", w.Body, err)
	}
	return value
}
