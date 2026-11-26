package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
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
		case "/directory":
			if r.Header.Get("Authorization") != "" {
				t.Error("sent Authorization to directory")
			}
			base := "http://" + r.Host
			_, _ = fmt.Fprintf(w, `{"results":[
				{"feedUrl":%q,"collectionName":"Cloudberry alias"},
				{"feedUrl":%q,"collectionName":"Cloudberry"},
				{"feedUrl":"https://paper.example/feed","collectionName":"Paper Planes"}
			]}`, base+"/old", base+"/feeds/cloudberry.xml")
		case "/old":
			http.Redirect(w, r, "/feeds/cloudberry.xml", http.StatusMovedPermanently)
		case "/bad-json":
			_, _ = w.Write([]byte(`{"title":"Fixture","items":[{"id":"episode\u0000","attachments":[{"url":"/audio.mp3"}]}]}`))
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
	call("GET", "/api/directory?q=berry", "", "", "", 401)
	call("DELETE", "/api/podcasts/1/new-episodes", "", "", "", 401)
	for range 5 {
		call("POST", "/api/login", `{"username":"listener","password":"wrong","device_name":"Test"}`, "", "", 401)
	}
	login := `{"username":"listener","password":"fixture password","device_name":"Test"}`
	call("POST", "/api/login", login, "", "", 429)
	loginReply := call("POST", "/api/login", login, "", "192.0.2.2:46001", 200)
	tokens := response[struct {
		Token    string `json:"token"`
		ID       int64  `json:"device_id"`
		ServerID string `json:"server_id"`
	}](t, loginReply)
	token = tokens.Token
	if len(token) != 43 || tokens.ID == 0 {
		t.Fatal("invalid login response")
	}
	var uuid pgtype.UUID
	if err := uuid.Scan(tokens.ServerID); err != nil || uuid.Bytes[6]>>4 != 4 || uuid.Bytes[8]>>6 != 2 {
		t.Fatalf("invalid server UUID in login reply: %v", err)
	}
	const directoryPath = "/api/directory?q=berry"
	if got := call("GET", directoryPath, "", "", "", 404).Body.String(); got != `{"error":"podcast directory is off"}` {
		t.Fatal(got)
	}
	directoryURL, urlErr := feedURL(feeds.URL + "/directory")
	if urlErr != nil {
		t.Fatal(urlErr)
	}
	refresh.directoryURL = directoryURL
	if got := call("GET", "/api/directory?q=a", "", "", "", 400).Body.String(); got != `{"error":"q must contain at least two characters"}` {
		t.Fatal(got)
	}
	checkDirectory := func(subscribed bool) {
		t.Helper()
		results := response[[]directoryPodcast](t, call("GET", directoryPath, "", "", "", 200))
		if len(results) != 3 || results[0].FeedURL != feeds.URL+"/old" ||
			results[1].FeedURL != feeds.URL+"/feeds/cloudberry.xml" ||
			results[2].FeedURL != "https://paper.example/feed" ||
			results[0].Subscribed != subscribed || results[1].Subscribed != subscribed ||
			results[2].Subscribed {
			t.Fatalf("directory subscribed = %t: %+v", subscribed, results)
		}
	}
	checkDirectory(false)

	call("POST", "/api/state", strings.Repeat(" ", maxRequestBytes+1), "", "", 413)
	call("POST", "/api/state", `{}{}`, "", "", 400)
	call("POST", "/api/state", `{"episodes":[{"episode_id":1,"updated_at":"2026-11-26T12:00:00.000Z"}]}`, "", "", 400)
	if got := call("GET", "/api/podcasts", "", "", "", 200).Body.String(); got != "[]" {
		t.Fatal(got)
	}
	emptyState := response[struct {
		stateSnapshot
		ServerTime timestamp `json:"server_time"`
	}](t, call("GET", "/api/state", "", "", "", 200))
	if emptyState.Episodes == nil || len(emptyState.Episodes) != 0 || emptyState.Queue != nil ||
		emptyState.ServerID != tokens.ServerID || !emptyState.ServerTime.Equal(now) {
		t.Fatalf("unexpected initial snapshot: %+v", emptyState)
	}
	call("POST", "/api/podcasts", `{"feed_url":"file:///a"}`, "", "", 422)
	if got := call("POST", "/api/podcasts", fmt.Sprintf(`{"feed_url":%q}`, feeds.URL+"/bad-json"), "", "", 422).Body.String(); !strings.Contains(got, errUnusableFeed.Error()) {
		t.Fatal(got)
	}
	input := fmt.Sprintf(`{"feed_url":%q}`, feeds.URL+"/old")
	p := response[podcast](t, call("POST", "/api/podcasts", input, "", "", 201))
	if p.EpisodeCount != 2 || p.FeedURL != feeds.URL+"/feeds/cloudberry.xml" || !p.ShowInNewEpisodes {
		t.Fatal(p)
	}
	checkDirectory(true)
	call("POST", "/api/podcasts", input, "", "", 200)
	if calls.Load() != 1 {
		t.Fatal("existing subscription triggered a fetch")
	}
	list := call("GET", "/api/podcasts", "", "", "", 200)
	podcastsTag := list.Header().Get("ETag")
	call("GET", "/api/podcasts", "", "W/"+podcastsTag, "", 304)
	podcastPath := fmt.Sprintf("/api/podcasts/%d", p.ID)
	newEpisodesPath := podcastPath + "/new-episodes"
	call("DELETE", "/api/podcasts/999999/new-episodes", "", "", "", 404)
	call("DELETE", newEpisodesPath, "", "", "", 204)
	updatedList := call("GET", "/api/podcasts", "", podcastsTag, "", 200)
	if updated := response[[]podcast](t, updatedList); len(updated) != 1 || updated[0].ShowInNewEpisodes ||
		updated[0].EpisodesVersion != p.EpisodesVersion || updatedList.Header().Get("ETag") == podcastsTag {
		t.Fatalf("preference did not update the podcast list: %+v", updated)
	}
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
	checkDirectory(false)
	queueOnly := response[[]podcast](t, call("GET", "/api/podcasts", "", "", "", 200))
	if len(queueOnly) != 1 || queueOnly[0].ID != p.ID || queueOnly[0].Subscribed {
		t.Fatalf("podcast with only a queued episode was lost: %+v", queueOnly)
	}
	if urls, err := parseOPML(call("GET", "/api/opml", "", "", "", 200).Body); err != nil || len(urls) != 0 {
		t.Fatalf("unsubscribed podcast was exported: %v, %v", urls, err)
	}
	resubscribed := response[podcast](t, call("POST", "/api/podcasts", input, "", "", 200))
	if !resubscribed.Subscribed || resubscribed.ShowInNewEpisodes {
		t.Fatal("resubscribing lost the New episodes preference")
	}
	checkDirectory(true)
	call("PUT", newEpisodesPath, "", "", "", 204)
	if shown := response[[]podcast](t, call("GET", "/api/podcasts", "", "", "", 200)); !shown[0].ShowInNewEpisodes {
		t.Fatalf("PUT did not show the podcast in New episodes: %+v", shown)
	}
	call("GET", "/api/episodes/999999/state", "", "", "", 404)
	call("GET", "/api/podcasts/999999/episodes", "", "", "", 404)
	call("GET", "/api/episodes/abc", "", "", "", 400)

	send := func(when time.Time, position int64, status string, duration *int64, ids []int64) stateResult {
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
		return response[stateResult](t, call("POST", "/api/state", string(body), "", "", 200))
	}
	at := now.Add(-time.Minute)
	measured, remeasured := int64(243210), int64(250123)
	result := send(at, 120000, "", &measured, []int64{paper.ID, 999999, copper.ID})
	if result.ServerID != tokens.ServerID || len(result.Episodes) != 1 || result.Episodes[0].PositionMS != 120000 ||
		result.Episodes[0].DurationMS == nil || *result.Episodes[0].DurationMS != measured ||
		!slices.Equal(result.Unknown, []int64{999999}) || result.Future == nil || len(result.Future) != 0 ||
		!slices.Equal(result.Queue.EpisodeIDs, []int64{paper.ID, copper.ID}) {
		t.Fatalf("initial state: %+v", result)
	}
	for _, stale := range []time.Time{at, at.Add(-time.Second)} {
		result = send(stale, 1, "played", &remeasured, []int64{})
		if result.Episodes[0].PositionMS != 120000 || result.Episodes[0].Status != "" ||
			result.Episodes[0].DurationMS == nil || *result.Episodes[0].DurationMS != measured || len(result.Queue.EpisodeIDs) != 2 {
			t.Fatalf("stale state replaced newer state: %+v", result)
		}
	}
	result = send(now.Add(24*time.Hour+time.Millisecond), 10, "dismissed", nil, []int64{})
	if result.Episodes == nil || len(result.Episodes) != 0 || len(result.Unknown) != 0 ||
		!slices.Equal(result.Future, []any{float64(copper.ID), float64(999999), "queue"}) ||
		result.Queue == nil || !result.Queue.UpdatedAt.Equal(at) {
		t.Fatalf("future records were not skipped: %+v", result)
	}
	badDuration := fmt.Sprintf(`{"episodes":[{"episode_id":%d,"position_ms":0,"status":"","duration_ms":1.5,"updated_at":"2026-11-26T12:00:00.000Z"}]}`, copper.ID)
	call("POST", "/api/state", badDuration, "", "", 400)
	invalidQueue := fmt.Sprintf(`{"episodes":[{"episode_id":%d,"position_ms":39000,"status":"","updated_at":"2026-11-26T12:00:00.000Z"}],"queue":{"updated_at":"2026-11-26T12:00:00.000Z"}}`, copper.ID)
	call("POST", "/api/state", invalidQueue, "", "", 400)
	snapshot := response[stateChange](t, call("GET", "/api/state", "", "", "", 200))
	if snapshot.Episodes[0].PositionMS != 120000 || snapshot.Episodes[0].DurationMS == nil ||
		*snapshot.Episodes[0].DurationMS != measured {
		t.Fatal("invalid queue request applied episode update")
	}
	mixed := fmt.Sprintf(`{"episodes":[
		{"episode_id":%d,"position_ms":60000,"status":"","duration_ms":%d,"updated_at":"2026-11-26T12:00:00.000Z"},
		{"episode_id":%d,"position_ms":0,"status":"played","updated_at":"2026-11-27T12:00:00.001Z"},
		{"episode_id":999999,"position_ms":0,"status":"","updated_at":"2026-11-26T12:00:00.000Z"}],
		"queue":{"episode_ids":[],"updated_at":"2026-11-27T12:00:00.001Z"}}`, copper.ID, remeasured, paper.ID)
	result = response[stateResult](t, call("POST", "/api/state", mixed, "", "", 200))
	if len(result.Episodes) != 1 || result.Episodes[0].EpisodeID != copper.ID || result.Episodes[0].PositionMS != 60000 ||
		result.Episodes[0].DurationMS == nil || *result.Episodes[0].DurationMS != remeasured ||
		!slices.Equal(result.Unknown, []int64{999999}) || !slices.Equal(result.Future, []any{float64(paper.ID), "queue"}) ||
		result.Queue == nil || !result.Queue.UpdatedAt.Equal(at) {
		t.Fatalf("mixed push did not apply just the valid records: %+v", result)
	}
	episodeReply := response[struct {
		State *episodeState `json:"state"`
	}](t, call("GET", copperPath+"/state", "", "", "", 200))
	if episodeReply.State == nil || episodeReply.State.DurationMS == nil || *episodeReply.State.DurationMS != remeasured {
		t.Fatal("single episode state did not return the stored duration")
	}
	result = send(now.Add(24*time.Hour), 0, "played", nil, []int64{})
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

func TestStateETagAndServerIdentity(t *testing.T) {
	s := integrationStore(t)
	testExec(t, s.db, `INSERT INTO users (username, password_hash) VALUES ('listener', decode('00', 'hex'));
		INSERT INTO podcasts (feed_url) VALUES ('https://fixture.invalid');
		INSERT INTO episodes (podcast_id, guid, title, enclosure_url, description, search_text)
			VALUES (1, 'fixture', 'Episode', 'https://fixture.invalid/audio.mp3', '', 'episode ')`)
	token, _, err := s.createDevice(t.Context(), "listener", "Reader")
	if err != nil {
		t.Fatal(err)
	}
	a := newAPI(s, nil)
	now := time.Date(2026, 11, 26, 12, 0, 0, 0, time.UTC)
	a.now = func() time.Time { return now }
	handler := a.routes()
	call := func(ctx context.Context, method, etag, body string, want int) *httptest.ResponseRecorder {
		t.Helper()
		r := httptest.NewRequestWithContext(ctx, method, "/api/state", strings.NewReader(body))
		r.Header.Set("Authorization", "Bearer "+token)
		if etag != "" {
			r.Header.Set("If-None-Match", etag)
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, r)
		if w.Code != want {
			t.Fatalf("%s state: %d, want %d: %s", method, w.Code, want, w.Body.String())
		}
		return w
	}

	ctx := t.Context()
	first := call(ctx, "GET", "", "", 200)
	identity := response[stateSnapshot](t, first).ServerID
	tag := first.Header().Get("ETag")
	if identity == "" || !strings.HasPrefix(tag, "W/") {
		t.Fatal("state response is missing the identity or a weak validator")
	}
	now = now.Add(time.Hour)
	tx, err := s.db.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	if _, err := tx.Exec(ctx, "LOCK TABLE episode_state IN ACCESS EXCLUSIVE MODE"); err != nil {
		t.Fatal(err)
	}
	conditionalCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	cached := call(conditionalCtx, "GET", `"unrelated", `+strings.TrimPrefix(tag, "W/"), "", 304)
	if cached.Body.Len() != 0 || cached.Header().Get("ETag") != tag {
		t.Fatal("304 had a body or lost its validator")
	}
	if err := tx.Rollback(ctx); err != nil {
		t.Fatal(err)
	}

	sample := fmt.Sprintf(`{"server_id":%q,"episodes":[{"episode_id":1,"position_ms":120000,"status":"","updated_at":"2026-11-26T12:00:00.000Z"}]}`, identity)
	call(ctx, "POST", "", sample, 200)
	updated := call(ctx, "GET", tag, "", 200)
	tag = updated.Header().Get("ETag")
	call(ctx, "POST", "", sample, 200)
	call(ctx, "GET", tag, "", 304)

	call(ctx, "POST", "", `{"queue":{"episode_ids":[1],"updated_at":"2026-11-26T12:01:00.000Z"}}`, 200)
	updated = call(ctx, "GET", tag, "", 200)
	tag = updated.Header().Get("ETag")
	call(ctx, "POST", "", `{"queue":{"episode_ids":[],"updated_at":"2026-11-26T12:02:00.000Z"}}`, 200)
	updated = call(ctx, "GET", tag, "", 200)
	tag = updated.Header().Get("ETag")

	t.Setenv("EASYPODCAST_DATABASE_URL", testDatabaseURL(t, s.db).String())
	if err := run(ctx, []string{"new-server-id"}); err != nil {
		t.Fatal(err)
	}
	updated = call(ctx, "GET", tag, "", 200)
	reset := response[stateSnapshot](t, updated)
	if reset.ServerID == "" || reset.ServerID == identity || len(reset.Episodes) != 1 ||
		reset.Episodes[0].PositionMS != 120000 || reset.Queue == nil || len(reset.Queue.EpisodeIDs) != 0 {
		t.Fatalf("identity reset changed the wrong records: %+v", reset)
	}
	stale := fmt.Sprintf(`{"server_id":%q,"episodes":[{"episode_id":1,"position_ms":4000,"status":"","updated_at":"2026-11-26T12:03:00.000Z"}],"queue":{"episode_ids":[1],"updated_at":"2026-11-26T12:03:00.000Z"}}`, identity)
	conflict := response[map[string]string](t, call(ctx, "POST", "", stale, 409))
	if conflict["server_id"] != reset.ServerID || conflict["error"] != "server identity changed" {
		t.Fatalf("wrong server identity conflict: %+v", conflict)
	}
	call(ctx, "GET", updated.Header().Get("ETag"), "", 304)
	if posted := response[stateResult](t, call(ctx, "POST", "", "{}", 200)); posted.ServerID != reset.ServerID {
		t.Fatalf("state update returned server ID %q after rotation", posted.ServerID)
	}
	if err := s.migrate(ctx); err != nil {
		t.Fatal(err)
	}
	if revision, err := s.currentStateRevision(ctx); err != nil || revision.ServerID != reset.ServerID {
		t.Fatalf("migrations replaced an existing identity: %v", err)
	}
}

func TestAPIDatabaseErrorLog(t *testing.T) {
	s := integrationStore(t)
	testExec(t, s.db, `INSERT INTO users (username, password_hash) VALUES ('listener', decode('00', 'hex'));
		DROP TABLE episode_state`)
	token, _, err := s.createDevice(t.Context(), "listener", "Reader")
	if err != nil {
		t.Fatal(err)
	}
	var logged bytes.Buffer
	old := slog.Default()
	slog.SetDefault(slog.New(slog.NewJSONHandler(&logged, nil)))
	defer slog.SetDefault(old)
	r := httptest.NewRequest("GET", "/api/episodes/123/state?filter=query-fixture", strings.NewReader("body-fixture"))
	r.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	newAPI(s, nil).routes().ServeHTTP(w, r)
	if w.Code != http.StatusInternalServerError || w.Body.String() != `{"error":"internal server error"}` {
		t.Fatalf("unexpected database error response: %d %s", w.Code, w.Body)
	}
	var entry struct {
		Method   string `json:"method"`
		Route    string `json:"route"`
		Status   int    `json:"status"`
		SQLState string `json:"sqlstate"`
	}
	if err := json.Unmarshal(logged.Bytes(), &entry); err != nil || entry.Method != "GET" ||
		entry.Route != "GET /api/episodes/{id}/state" || entry.Status != 500 || entry.SQLState != "42P01" {
		t.Fatalf("missing safe database error diagnostics: %+v, %v", entry, err)
	}
	for _, sensitive := range []string{token, "123/state", "query-fixture", "body-fixture"} {
		if strings.Contains(logged.String(), sensitive) {
			t.Fatal("database error log exposed request data")
		}
	}
}

func TestLoginTrustedProxy(t *testing.T) {
	s := integrationStore(t)
	if err := s.setPassword(t.Context(), "listener", "fixture password"); err != nil {
		t.Fatal(err)
	}
	a := newAPI(s, nil)
	a.logins.trustedProxies = parseTrustedProxies("malformed, 192.0.2.0/24, 198.51.100.9")
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
		login("192.0.2.2:41000", spoof+", 198.51.100.2, 198.51.100.9", "wrong", 401)
		login(fmt.Sprintf("203.0.113.2:%d", 42000+i), spoof, "wrong", 401)
	}
	login("192.0.2.2:41001", "203.0.113.90, 198.51.100.2", "fixture password", 429)
	login("203.0.113.2:42005", "203.0.113.91", "fixture password", 429)
	login("192.0.2.2:41002", "198.51.100.3, 198.51.100.9", "fixture password", 200)
}

func TestLoginGlobalLimitAtAPI(t *testing.T) {
	s := integrationStore(t)
	if err := s.setPassword(t.Context(), "listener", "fixture password"); err != nil {
		t.Fatal(err)
	}
	token, _, err := s.createDevice(t.Context(), "listener", "Existing reader")
	if err != nil {
		t.Fatal(err)
	}
	a := newAPI(s, nil)
	const login = `{"username":"listener","password":"fixture password","device_name":"New reader"}`
	req := httptest.NewRequest("POST", "/api/login", strings.NewReader(login))
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
	req = httptest.NewRequest("GET", "/api/state", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec = httptest.NewRecorder()
	a.routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("global login block affected an existing token: HTTP %d", rec.Code)
	}
	rec = httptest.NewRecorder()
	newAPI(s, nil).routes().ServeHTTP(rec, httptest.NewRequest("POST", "/api/login", strings.NewReader(login)))
	if rec.Code != http.StatusOK {
		t.Fatalf("a fresh server still had a login block: HTTP %d", rec.Code)
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
