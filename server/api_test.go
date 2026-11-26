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
	t.Setenv("EASYPODCAST_ALLOW_PRIVATE_FEEDS", "true")
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
	queued := fmt.Sprintf(`{"queue":{"episode_ids":[%d],"updated_at":"2026-11-26T11:58:00.000Z"}}`, paper.ID)
	call("POST", "/api/state", queued, "", "", 200)
	call("DELETE", podcastPath, "", "", "", 204)
	queueOnly := response[[]podcast](t, call("GET", "/api/podcasts", "", "", "", 200))
	if len(queueOnly) != 1 || queueOnly[0].ID != p.ID || queueOnly[0].Subscribed {
		t.Fatalf("podcast with only a queued episode was lost: %+v", queueOnly)
	}
	if urls, err := parseOPML(call("GET", "/api/opml", "", "", "", 200).Body); err != nil || len(urls) != 0 {
		t.Fatalf("unsubscribed podcast was exported: %v, %v", urls, err)
	}
	call("POST", "/api/podcasts", input, "", "", 200)
	call("GET", "/api/episodes/999999/state", "", "", "", 404)
	call("GET", "/api/podcasts/999999/episodes", "", "", "", 404)
	call("GET", "/api/episodes/abc", "", "", "", 400)

	send := func(when time.Time, position int64, status string, duration *int64, ids []int64, code int) *httptest.ResponseRecorder {
		body, err := json.Marshal(stateChange{
			Episodes: []episodeState{
				{EpisodeID: copper.ID, PositionMS: position, Status: status, DurationMS: duration, UpdatedAt: timestamp{when}},
				{EpisodeID: 999999, UpdatedAt: timestamp{when}},
			},
			Queue: &queue{ids, timestamp{when}},
		})
		if err != nil {
			t.Fatal(err)
		}
		return call("POST", "/api/state", string(body), "", "", code)
	}
	at := now.Add(-time.Minute)
	measured, remeasured := int64(243210), int64(250123)
	result := response[stateResult](t, send(at, 120000, "", &measured, []int64{paper.ID, 999999, copper.ID}, 200))
	if len(result.Episodes) != 1 || result.Episodes[0].PositionMS != 120000 ||
		result.Episodes[0].DurationMS == nil || *result.Episodes[0].DurationMS != measured ||
		!slices.Equal(result.Unknown, []int64{999999}) || !slices.Equal(result.Queue.EpisodeIDs, []int64{paper.ID, copper.ID}) {
		t.Fatalf("initial state: %+v", result)
	}
	for _, stale := range []time.Time{at, at.Add(-time.Second)} {
		result = response[stateResult](t, send(stale, 1, "played", &remeasured, []int64{}, 200))
		if result.Episodes[0].PositionMS != 120000 || result.Episodes[0].Status != "" ||
			result.Episodes[0].DurationMS == nil || *result.Episodes[0].DurationMS != measured || len(result.Queue.EpisodeIDs) != 2 {
			t.Fatalf("stale state replaced newer state: %+v", result)
		}
	}
	send(now.Add(24*time.Hour+time.Millisecond), 10, "dismissed", nil, []int64{}, 400)
	badDuration := fmt.Sprintf(`{"episodes":[{"episode_id":%d,"position_ms":0,"status":"","duration_ms":1.5,"updated_at":"2026-11-26T12:00:00.000Z"}]}`, copper.ID)
	call("POST", "/api/state", badDuration, "", "", 400)
	invalidQueue := fmt.Sprintf(`{"episodes":[{"episode_id":%d,"position_ms":39000,"status":"","updated_at":"2026-11-26T12:00:00.000Z"}],"queue":{"episode_ids":[],"updated_at":"2026-11-28T12:00:00.000Z"}}`, copper.ID)
	call("POST", "/api/state", invalidQueue, "", "", 400)
	snapshot := response[stateChange](t, call("GET", "/api/state", "", "", "", 200))
	if snapshot.Episodes[0].PositionMS != 120000 || snapshot.Episodes[0].DurationMS == nil ||
		*snapshot.Episodes[0].DurationMS != measured {
		t.Fatal("invalid queue request applied episode update")
	}
	result = response[stateResult](t, send(now, 60000, "", &remeasured, []int64{copper.ID}, 200))
	if result.Episodes[0].PositionMS != 60000 || result.Episodes[0].DurationMS == nil || *result.Episodes[0].DurationMS != remeasured {
		t.Fatal("newer rewind did not win")
	}
	episodeReply := response[struct {
		State *episodeState `json:"state"`
	}](t, call("GET", copperPath+"/state", "", "", "", 200))
	if episodeReply.State == nil || episodeReply.State.DurationMS == nil || *episodeReply.State.DurationMS != remeasured {
		t.Fatal("single episode state did not return the stored duration")
	}
	result = response[stateResult](t, send(now.Add(24*time.Hour), 0, "played", nil, []int64{}, 200))
	if result.Episodes[0].Status != "played" || result.Episodes[0].DurationMS != nil ||
		result.Queue.EpisodeIDs == nil || len(result.Queue.EpisodeIDs) != 0 {
		t.Fatal("newer completion did not win")
	}
	if got := call("GET", copperPath+"/state", "", "", "", 200).Body.String(); !strings.Contains(got, `"status":"played","duration_ms":null`) {
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

func TestLoginTrustedProxy(t *testing.T) {
	s := integrationStore(t)
	if err := s.setPassword(t.Context(), "listener", "fixture password"); err != nil {
		t.Fatal(err)
	}
	a := newAPI(s, nil)
	a.logins.trustedProxies = parseTrustedProxies("malformed, 192.0.2.0/24")
	handler := a.routes()
	login := func(peer, forwarded, password string, want int) {
		t.Helper()
		req := httptest.NewRequest("POST", "/api/login",
			strings.NewReader(fmt.Sprintf(`{"username":"listener","password":%q,"device_name":"Test"}`, password)))
		req.RemoteAddr = peer
		req.Header.Set("X-Forwarded-For", forwarded)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code != want {
			t.Fatalf("peer %s with X-Forwarded-For %s: HTTP %d, want %d", peer, forwarded, rec.Code, want)
		}
	}
	for i := range 5 {
		spoof := fmt.Sprintf("203.0.113.%d", i+10)
		login("192.0.2.2:41000", spoof+", 198.51.100.2", "wrong", 401)
		login(fmt.Sprintf("203.0.113.2:%d", 42000+i), spoof, "wrong", 401)
	}
	login("192.0.2.2:41001", "203.0.113.90, 198.51.100.2", "fixture password", 429)
	login("203.0.113.2:42005", "203.0.113.91", "fixture password", 429)
	login("192.0.2.2:41002", "198.51.100.3", "fixture password", 200)
}

func TestLoginGlobalLimitAtAPI(t *testing.T) {
	a := newAPI(store{}, nil)
	req := httptest.NewRequest("POST", "/api/login", strings.NewReader(`{"username":"listener","password":"guess","device_name":"Test"}`))
	for i := range loginMinuteLimit {
		req.RemoteAddr = fmt.Sprintf("198.51.100.%d:8080", i+1)
		finish, wait := a.logins.start(req)
		if wait != 0 {
			t.Fatalf("unexpected global limit at %d failures", i)
		}
		finish(true)
	}
	req.RemoteAddr = "203.0.113.1:8080"
	rec := httptest.NewRecorder()
	a.routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusTooManyRequests || rec.Header().Get("Retry-After") == "" {
		t.Fatalf("rotated address got HTTP %d without a rate limit, %v", rec.Code, rec.Header())
	}
}

func response[T any](t *testing.T, w *httptest.ResponseRecorder) T {
	t.Helper()
	var value T
	if err := json.Unmarshal(w.Body.Bytes(), &value); err != nil {
		t.Fatalf("response %s: %v", w.Body, err)
	}
	return value
}
