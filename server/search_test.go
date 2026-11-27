package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"testing"
	"time"
)

func TestEpisodeSearch(t *testing.T) {
	s := integrationStore(t)
	ctx := t.Context()
	base := &url.URL{Scheme: "https", Host: "fixture.invalid", Path: "/test"}
	const date = "26 Nov 26 09:15 GMT"
	const second = `<item><guid>guest</guid><title>The Interview</title><pubDate>` + date + `</pubDate>
		<description><![CDATA[<p>Tech guys meet <b>Tomáš Roud</b>.</p><script>hidden</script>]]></description>
		<enclosure url="/guest.mp3"/></item>`
	doc, err := parseFeed(ctx, []byte(testRSS(testRSSItem("title", "Tech Guys", date, "/title.mp3"), second)), base)
	if err != nil {
		t.Fatal(err)
	}
	podcastID, _, err := s.addFeed(ctx, base.String(), feedResponse{url: base.String(), document: doc}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	testExec(t, s.db, `INSERT INTO podcasts (feed_url, subscribed)
		VALUES ('https://fixture.invalid/other', true), ('https://fixture.invalid/unsubscribed', false)`)
	testExec(t, s.db, `INSERT INTO episodes (podcast_id, guid, title, enclosure_url, published_at, description, search_text)
		SELECT $1, '', 'Archive', '/archive/' || n, timestamptz '2020-01-01 UTC', 'Tech Guys', 'archive tech guys'
		FROM generate_series(1, 201) n
		UNION ALL SELECT id, '', 'Tech Guys', '/other.mp3', timestamptz '2030-01-01 UTC', 'Tomáš Roud', 'tech guys tomas roud'
		FROM podcasts WHERE id <> $1`, podcastID)
	testExec(t, s.db, `INSERT INTO users (username, password_hash) VALUES ('listener', decode('00', 'hex'))`)
	token, _, err := s.createDevice(ctx, "listener", "Reader")
	if err != nil {
		t.Fatal(err)
	}
	handler := newAPI(s, nil).routes()
	path := fmt.Sprintf("/api/podcasts/%d/search", podcastID)
	get := func(path, token string, status int) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequestWithContext(ctx, http.MethodGet, path, nil)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		res := httptest.NewRecorder()
		handler.ServeHTTP(res, req)
		if res.Code != status {
			t.Fatalf("GET %s: got %d, want %d: %s", path, res.Code, status, res.Body)
		}
		return res
	}
	search := func(path, query string, want []int64) {
		t.Helper()
		res := get(path+"?q="+url.QueryEscape(query), token, http.StatusOK)
		got := response[struct {
			IDs []int64 `json:"episode_ids"`
		}](t, res).IDs
		if got == nil || !slices.Equal(got, want) {
			t.Fatalf("search %q: got IDs %v, want %v", query, got, want)
		}
	}
	get(path+"?q=tech", "", http.StatusUnauthorized)
	get(path, token, http.StatusBadRequest)
	for _, q := range []string{"", " \t ", " š ", "a\x00b"} {
		get(path+"?q="+url.QueryEscape(q), token, http.StatusBadRequest)
	}
	get("/api/podcasts/999999/search?q=tech", token, http.StatusNotFound)
	items, err := s.episodes(ctx, podcastID)
	if err != nil || len(items) != 203 {
		t.Fatalf("episode list: got %d items, %v", len(items), err)
	}
	ordered := make([]int64, 200)
	for i := range ordered {
		ordered[i] = items[i].ID
	}
	search(path, " TECh\tguYs ", ordered)
	search(path, "tomas roud", []int64{items[1].ID})
	search(path, "ROUD interview Tomas\u0301", []int64{items[1].ID})
	search(path, "tech roud missing", nil)
	search(path, "hidden", nil)
	search(path, "tech %_", nil)

	var otherID int64
	if err := s.db.QueryRow(ctx, `SELECT e.id FROM episodes e JOIN podcasts p ON p.id = e.podcast_id
		WHERE p.feed_url = 'https://fixture.invalid/other'`).Scan(&otherID); err != nil {
		t.Fatal(err)
	}
	const global = "/api/search"
	get(global+"?q=tech", "", http.StatusUnauthorized)
	get(global+"?q=t", token, http.StatusBadRequest)
	search(global, " ROUD\tTOMÁŠ ", []int64{otherID, items[1].ID})
	search(global, "tech guys", ordered[1:101])
	search(global, "interview", nil)
	search(global, "tech roud missing", nil)
	var undated, dated int64
	for _, row := range []struct {
		id        *int64
		published any
	}{{&undated, nil}, {&dated, "2021-01-01T00:00:00Z"}} {
		if err := s.db.QueryRow(ctx, `INSERT INTO episodes (podcast_id, guid, title, enclosure_url, published_at, description, search_text)
			SELECT id, '', 'Stripes', '/zebra/' || gen_random_uuid(), $1::timestamptz, 'Zebra', 'stripes zebra'
			FROM podcasts WHERE feed_url = 'https://fixture.invalid/other' RETURNING id`, row.published).Scan(row.id); err != nil {
			t.Fatal(err)
		}
	}
	testExec(t, s.db, `INSERT INTO episodes (podcast_id, guid, title, enclosure_url, published_at, description, search_text)
		SELECT id, '', 'Zébra', '/titled/' || n, timestamptz '2031-01-01 UTC', '', 'zebra'
		FROM podcasts, generate_series(1, 101) n WHERE feed_url = 'https://fixture.invalid/other'`)
	search(global, "zebra", []int64{dated, undated})

	target, err := s.feedTarget(ctx, podcastID)
	if err != nil {
		t.Fatal(err)
	}
	doc.episodes[1].Description = "Revised show notes"
	if err := s.applyRefresh(ctx, target, feedResponse{url: base.String(), document: doc}, time.Now()); err != nil {
		t.Fatal(err)
	}
	search(path, "tomas roud", nil)
	search(path, "revised notes", []int64{items[1].ID})
}
