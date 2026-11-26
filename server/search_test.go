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
	testExec(t, s.db, `INSERT INTO podcasts (feed_url) VALUES ('https://fixture.invalid/other')`)
	testExec(t, s.db, `INSERT INTO episodes (podcast_id, guid, title, enclosure_url, published_at, description, search_text)
		SELECT $1, '', 'Tech Guys', '/archive/' || n, timestamptz '2020-01-01 UTC', '', 'tech guys'
		FROM generate_series(1, 201) n
		UNION ALL SELECT id, '', 'Tech Guys', '/other.mp3', timestamptz '2030-01-01 UTC', 'Tomáš Roud', 'tech guys tomas roud'
		FROM podcasts WHERE feed_url = 'https://fixture.invalid/other'`, podcastID)
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
	search := func(query string, want []int64) {
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
	search(" TECh\tguYs ", ordered)
	search("tomas roud", []int64{items[1].ID})
	search("ROUD interview Tomas\u0301", []int64{items[1].ID})
	search("tech roud missing", nil)
	search("hidden", nil)
	search("tech %_", nil)

	target, err := s.feedTarget(ctx, podcastID)
	if err != nil {
		t.Fatal(err)
	}
	doc.episodes[1].Description = "Revised show notes"
	if err := s.applyRefresh(ctx, target, feedResponse{url: base.String(), document: doc}, time.Now()); err != nil {
		t.Fatal(err)
	}
	search("tomas roud", nil)
	search("revised notes", []int64{items[1].ID})
}
