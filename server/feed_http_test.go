package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestPublicFeedAddress(t *testing.T) {
	for _, ip := range []string{
		"0.1.2.3", "127.0.0.1", "10.0.0.1", "172.16.0.1", "192.168.1.1", "169.254.2.1", "100.64.0.1",
		"::", "::1", "::ffff:127.0.0.1", "fe80::1%eth0", "fd01::1", "ff02::1", "64:ff9b::c0a8:101",
	} {
		addr := net.JoinHostPort(ip, "80")
		if err := publicFeedAddress("tcp", addr, nil); !errors.Is(err, errPrivateFeed) {
			t.Errorf("accepted %s: %v", addr, err)
		}
	}
	for _, ip := range []string{"8.8.8.8", "2606:4700:4700::1111"} {
		addr := net.JoinHostPort(ip, "443")
		if err := publicFeedAddress("tcp", addr, nil); err != nil {
			t.Errorf("rejected %s: %v", addr, err)
		}
	}
}

func TestFetchChecksResolvedAddressesOnRedirect(t *testing.T) {
	t.Setenv("EASYPODCAST_ALLOW_PRIVATE_FEEDS", "false")
	feed := fixture(t, "first.xml")
	var requests atomic.Int32
	private := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		requests.Add(1)
		_, _ = w.Write(feed)
	}))
	defer private.Close()
	privateHost := strings.Replace(private.URL, "127.0.0.1", "localhost", 1)
	redirector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		http.Redirect(w, req, privateHost, http.StatusFound)
	}))
	defer redirector.Close()
	r := newRefresher(store{}, "EasyPodcast/test", time.Hour)
	transport := r.client.Transport.(*http.Transport)
	defer transport.CloseIdleConnections()
	guarded := transport.DialContext
	transport.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
		if addr == "publisher.invalid:80" {
			return (&net.Dialer{}).DialContext(ctx, network, redirector.Listener.Addr().String())
		}
		return guarded(ctx, network, addr)
	}
	for _, target := range []string{private.URL, privateHost, "http://publisher.invalid/redirect"} {
		if _, err := r.fetch(t.Context(), feedTarget{URL: target}); !errors.Is(err, errPrivateFeed) {
			t.Errorf("fetch %s: %v, want %v", target, err, errPrivateFeed)
		}
	}
	if requests.Load() != 0 {
		t.Fatal("private feed was contacted")
	}
	t.Setenv("EASYPODCAST_ALLOW_PRIVATE_FEEDS", "true")
	allowed := newRefresher(store{}, "EasyPodcast/test", time.Hour)
	if res, err := allowed.fetch(t.Context(), feedTarget{URL: private.URL}); err != nil || res.document == nil {
		t.Fatalf("private test feed with opt-out: %+v, %v", res, err)
	}
}

type feedBodyError struct{ err error }

func (r feedBodyError) Read([]byte) (int, error) { return 0, r.err }
func (r feedBodyError) Close() error             { return nil }

func TestFetchRetainsBodyReadTimeout(t *testing.T) {
	r := newRefresher(store{}, "EasyPodcast/test", time.Hour)
	r.client.Transport = feedRoundTripFunc(func(req *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusOK,
			Body:       feedBodyError{err: fmt.Errorf("reading fixture-secret: %w", context.DeadlineExceeded)},
			Request:    req,
		}, nil
	})
	if _, err := r.fetch(t.Context(), feedTarget{URL: "http://feed.invalid"}); err != errFeedTimeout {
		t.Fatalf("feed body timeout: %v", err)
	}
}

func TestFetchRetainsTLSFailure(t *testing.T) {
	t.Setenv("EASYPODCAST_ALLOW_PRIVATE_FEEDS", "true")
	publisher := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		_, _ = io.WriteString(w, "<rss/>")
	}))
	defer publisher.Close()
	r := newRefresher(store{}, "EasyPodcast/test", time.Hour)
	if _, err := r.fetch(t.Context(), feedTarget{URL: publisher.URL}); err != feedError("feed TLS certificate not accepted") {
		t.Fatalf("feed TLS verification: %v", err)
	}
}
