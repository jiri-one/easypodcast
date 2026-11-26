package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestOPMLImportUsesFourWorkersAndReportsDeadline(t *testing.T) {
	t.Setenv("EASYPODCAST_ALLOW_PRIVATE_FEEDS", "true")
	s := integrationStore(t)
	var started atomic.Int32
	feeds := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		started.Add(1)
		<-req.Context().Done()
	}))
	defer feeds.Close()
	r := newRefresher(s, "EasyPodcast/test", time.Hour)
	var urls []string
	for i := range 6 {
		urls = append(urls, fmt.Sprintf("%s/feed%d", feeds.URL, i))
	}
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
	defer cancel()
	result, err := r.importOPML(ctx, urls)
	if err != nil || result.Added != 0 || result.Existing != 0 || len(result.Failed) != len(urls) {
		t.Fatalf("import result %+v, %v", result, err)
	}
	if got := started.Load(); got != 4 {
		t.Fatalf("%d requests started before the deadline, want 4", got)
	}
	for i, failure := range result.Failed {
		want := errFeedTimeout.Error()
		if i >= 4 {
			want = "not imported in time, import the file again"
		}
		if failure.FeedURL != urls[i] || failure.Error != want {
			t.Fatalf("feed %d: %+v, want %s", i, failure, want)
		}
	}
}

func TestOPMLImportSurvivesRequestCancellation(t *testing.T) {
	t.Setenv("EASYPODCAST_ALLOW_PRIVATE_FEEDS", "true")
	s := integrationStore(t)
	feed := fixture(t, "first.xml")
	entered := make(chan struct{})
	release := make(chan struct{}, 1)
	feeds := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(entered)
		select {
		case <-release:
			_, _ = w.Write(feed)
		case <-r.Context().Done():
		}
	}))
	defer feeds.Close()
	defer func() { close(release) }()
	r := newRefresher(s, "EasyPodcast/test", time.Hour)
	a := newAPI(s, r)
	body := fmt.Sprintf(`<opml><body><outline xmlUrl="%s"/></body></opml>`, feeds.URL)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	req := httptest.NewRequestWithContext(ctx, "POST", "/api/opml", strings.NewReader(body))
	rec := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		a.importOPML(rec, req)
		close(done)
	}()
	select {
	case <-entered:
	case <-done:
		t.Fatalf("import ended before starting feed fetch: %s", rec.Body.String())
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for feed fetch")
	}
	cancel()
	release <- struct{}{}
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for detached import")
	}
	if result := response[opmlResult](t, rec); rec.Code != http.StatusOK || result.Added != 1 || len(result.Failed) != 0 {
		t.Fatalf("import after disconnect: HTTP %d, %+v", rec.Code, result)
	}
}
