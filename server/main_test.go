package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func pointHealthcheckAt(t *testing.T, server *httptest.Server) {
	t.Helper()
	_, port, err := net.SplitHostPort(strings.TrimPrefix(server.URL, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("EASYPODCAST_LISTEN", "[::]:"+port)
	t.Setenv("EASYPODCAST_DATABASE_URL", "")
}

func TestHealthcheck(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		want   string
	}{
		{"ready", http.StatusOK, ""},
		{"unavailable", http.StatusServiceUnavailable, "healthcheck returned HTTP 503"},
		{"redirect", http.StatusFound, "healthcheck returned HTTP 302"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			mux := http.NewServeMux()
			mux.HandleFunc("GET /ready", func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(http.StatusOK)
			})
			mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
				if tc.status == http.StatusFound {
					http.Redirect(w, r, "/ready", tc.status)
					return
				}
				w.WriteHeader(tc.status)
			})
			server := httptest.NewServer(mux)
			defer server.Close()
			pointHealthcheckAt(t, server)
			err := run(t.Context(), []string{"healthcheck"})
			if tc.want == "" {
				if err != nil {
					t.Fatal(err)
				}
			} else if err == nil || err.Error() != tc.want {
				t.Fatalf("got %v, want %s", err, tc.want)
			}
		})
	}
}

func TestHealthcheckTimeout(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	defer server.Close()
	pointHealthcheckAt(t, server)
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	if err := run(ctx, []string{"healthcheck"}); !errors.Is(err, context.DeadlineExceeded) || ctx.Err() != nil {
		t.Fatalf("expected healthcheck to time out before the caller: %v", err)
	}
}
