package main

import (
	"bytes"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func directoryRefresher(t *testing.T, address string) *refresher {
	t.Helper()
	r := newRefresher(store{}, "EasyPodcast/test", time.Hour)
	var err error
	r.directoryURL, err = feedURL(address)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestDirectoryRequest(t *testing.T) {
	t.Setenv("EASYPODCAST_ALLOW_PRIVATE_FEEDS", "true")
	var requests atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		requests.Add(1)
		if req.Method != http.MethodGet || req.UserAgent() != "EasyPodcast/test" {
			t.Errorf("unexpected method or User-Agent: %s %q", req.Method, req.UserAgent())
		}
		query := req.URL.Query()
		for key, want := range map[string]string{
			"term": "noční vlak", "media": "podcast", "entity": "podcast", "limit": "25", "country": "CZ",
		} {
			if values := query[key]; len(values) != 1 || values[0] != want {
				t.Errorf("%s = %q, want %q", key, values, want)
			}
		}
		w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
		_, _ = io.WriteString(w, "\n\n\n"+`{"results":[]}`)
	}))
	defer upstream.Close()
	const config = "country=CZ&limit=50&term=old&media=music&entity=album"
	r := directoryRefresher(t, upstream.URL+"?"+config)
	for range cap(r.slots) {
		r.slots <- struct{}{}
	}
	w := httptest.NewRecorder()
	newAPI(store{}, r).searchDirectory(w, httptest.NewRequest(http.MethodGet, "/api/directory?q=+no%C4%8Dn%C3%AD+vlak+", nil))
	if w.Code != http.StatusOK || w.Body.String() != "[]" {
		t.Fatalf("directory response: %d %s", w.Code, w.Body.String())
	}
	if requests.Load() != 1 || r.directoryURL.RawQuery != config {
		t.Fatal("directory search sent multiple requests or changed its configuration")
	}
}

func TestDirectoryMapping(t *testing.T) {
	t.Setenv("EASYPODCAST_ALLOW_PRIVATE_FEEDS", "true")
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, `{"results":[
			{"collectionName":"Missing feed"},
			{"feedUrl":"ftp://feeds.example/a","collectionName":"FTP"},
			{"feedUrl":"https://user:pw@feeds.example/a","collectionName":"Credentials"},
			{"feedUrl":"","collectionName":"Empty feed"},
			{"feedUrl":"https://feeds.example/a","collectionName":"  "},
			{"feedUrl":" HTTPS://FEEDS.example:443/a ","collectionName":" First show ",
			 "artistName":" First author ","artworkUrl100":"https://images.example/first.jpg"},
			{"feedUrl":"https://feeds.example/a","collectionName":"Duplicate"},
			{"feedUrl":"https://feeds.example/b","collectionName":"Second show","artworkUrl100":"javascript:void(0)"},
			{"feedUrl":"https://feeds.example/c","collectionName":"Third show","artworkUrl100":"//images.example/third.jpg"},
			{"feedUrl":"https://feeds.example/d","collectionName":"Fourth show","artworkUrl100":"https://user:pw@images.example/fourth.jpg"}`)
		for i := range 26 {
			_, _ = fmt.Fprintf(w, `,{"feedUrl":"https://feeds.example/%d","collectionName":"Show %d"}`, i, i)
		}
		_, _ = io.WriteString(w, `]}`)
	}))
	defer upstream.Close()
	r := directoryRefresher(t, upstream.URL)
	results, err := r.searchDirectory(t.Context(), "test")
	if err != nil || len(results) != directoryLimit {
		t.Fatalf("got %d results, %v", len(results), err)
	}
	first := results[0]
	if first.FeedURL != "https://feeds.example/a" || first.Title != "First show" || first.Author != "First author" ||
		first.ImageURL == nil || *first.ImageURL != "https://images.example/first.jpg" || first.Subscribed {
		t.Fatalf("first result: %+v", first)
	}
	for i, title := range []string{"Second show", "Third show", "Fourth show"} {
		item := results[i+1]
		if item.Title != title || item.Author != "" || item.ImageURL != nil {
			t.Errorf("result %d: %+v", i+1, item)
		}
	}
	for i, item := range results[4:] {
		if item.Title != fmt.Sprintf("Show %d", i) || item.ImageURL != nil {
			t.Errorf("result %d: %+v", i+4, item)
		}
	}
}

func TestDirectoryResponseFailures(t *testing.T) {
	t.Setenv("EASYPODCAST_ALLOW_PRIVATE_FEEDS", "true")
	for _, tc := range []struct {
		name   string
		status int
		body   string
		reason string
	}{
		{"unavailable", 503, "", "HTTP 503"},
		{"HTML", 200, "<html>proxy error</html>", "invalid response"},
		{"missing results", 200, `{"resultCount":0}`, "invalid response"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tc.status)
				_, _ = io.WriteString(w, tc.body)
			}))
			defer upstream.Close()
			expectDirectoryFailure(t, directoryRefresher(t, upstream.URL), tc.reason)
		})
	}
	t.Run("oversized after decompression", func(t *testing.T) {
		upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Encoding", "gzip")
			compressed := gzip.NewWriter(w)
			_, _ = io.WriteString(compressed, strings.Repeat(" ", maxDirectoryBytes)+`{"results":[]}`)
			_ = compressed.Close()
		}))
		defer upstream.Close()
		expectDirectoryFailure(t, directoryRefresher(t, upstream.URL), "response too large")
	})
	t.Run("endless", func(t *testing.T) {
		upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
			chunk := []byte(strings.Repeat(" ", 64<<10))
			for sent := 0; req.Context().Err() == nil; sent += len(chunk) {
				// Socket buffers alone can take a few megabytes.
				if sent > 64*maxDirectoryBytes {
					t.Error("directory body was read far past its limit")
					return
				}
				_, _ = w.Write(chunk)
			}
		}))
		defer upstream.Close()
		expectDirectoryFailure(t, directoryRefresher(t, upstream.URL), "response too large")
	})
}

func TestDirectoryTransportFailures(t *testing.T) {
	t.Run("transport error", func(t *testing.T) {
		r := directoryRefresher(t, "https://directory.example/search")
		r.client.Transport = feedRoundTripFunc(func(req *http.Request) (*http.Response, error) {
			deadline, ok := req.Context().Deadline()
			if !ok || time.Until(deadline) > 8*time.Second || time.Until(deadline) <= 0 {
				t.Errorf("unexpected directory deadline: %v", deadline)
			}
			return nil, errors.New("confidential transport details")
		})
		expectDirectoryFailure(t, r, "directory request failed")
	})
	t.Run("private address", func(t *testing.T) {
		t.Setenv("EASYPODCAST_ALLOW_PRIVATE_FEEDS", "false")
		upstream := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
			t.Error("request reached loopback")
		}))
		defer upstream.Close()
		expectDirectoryFailure(t, directoryRefresher(t, upstream.URL), errPrivateFeed.Error())
	})
}

func expectDirectoryFailure(t *testing.T, r *refresher, reason string) {
	t.Helper()
	var logs bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&logs, nil)))
	defer slog.SetDefault(previous)
	w := httptest.NewRecorder()
	newAPI(store{}, r).searchDirectory(w, httptest.NewRequest(http.MethodGet, "/api/directory?q=listener-query", nil))
	if w.Code != http.StatusBadGateway || w.Body.String() != `{"error":"podcast directory unavailable"}` {
		t.Fatalf("directory failure: %d %s", w.Code, w.Body.String())
	}
	log := logs.String()
	if strings.Count(log, "level=WARN") != 1 || !strings.Contains(log, reason) ||
		strings.Contains(log, "listener-query") || strings.Contains(log, r.directoryURL.Host) ||
		strings.Contains(log, "confidential transport details") {
		t.Fatalf("unexpected log: %s", log)
	}
}

func TestConfigureDirectory(t *testing.T) {
	t.Setenv("EASYPODCAST_REFRESH_INTERVAL", "")
	t.Setenv("EASYPODCAST_DIRECTORY_URL", "")
	r, err := configureRefresher(store{})
	if err != nil || r.directoryURL == nil || r.directoryURL.String() != "https://itunes.apple.com/search" {
		t.Fatalf("default directory: %v, %v", r, err)
	}
	t.Setenv("EASYPODCAST_DIRECTORY_URL", "off")
	r, err = configureRefresher(store{})
	if err != nil || r.directoryURL != nil {
		t.Fatalf("directory was not disabled: %v, %v", r, err)
	}
	for _, address := range []string{"ftp://x.example", "https://user:pw@x.example/", "not a url"} {
		t.Setenv("EASYPODCAST_DIRECTORY_URL", address)
		if _, err := configureRefresher(store{}); err == nil ||
			err.Error() != "EASYPODCAST_DIRECTORY_URL must be an HTTP or HTTPS URL or off" {
			t.Errorf("invalid directory URL %q: %v", address, err)
		}
	}
}
