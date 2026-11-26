package main

import (
	"fmt"
	"net/http/httptest"
	"testing"
	"time"
)

func TestTrustedProxyAddress(t *testing.T) {
	limiter := loginLimiter{trustedProxies: parseTrustedProxies(" , 192.0.2.7/32, 2001:db8::/48, 203.0.113.1, 2001:db8:2::1")}
	for _, tc := range []struct {
		name      string
		peer      string
		forwarded []string
		want      string
	}{
		{"trusted IPv4", "192.0.2.7:8080", []string{"203.0.113.1, 198.51.100.8 "}, "198.51.100.8"},
		{"trusted IPv6", "[2001:db8::7]:8080", []string{"203.0.113.1", "2001:0db8:1::8"}, "2001:db8:1::8"},
		{"bare IPv4 proxy", "203.0.113.1:8080", []string{"198.51.100.8"}, "198.51.100.8"},
		{"bare IPv6 proxy", "[2001:db8:2::1]:8080", []string{"198.51.100.8"}, "198.51.100.8"},
		{"two proxies", "192.0.2.7:8080", []string{"203.0.113.50, 198.51.100.8", "203.0.113.1"}, "198.51.100.8"},
		{"only trusted proxies", "192.0.2.7:8080", []string{"203.0.113.1, 2001:db8:2::1"}, "192.0.2.7"},
		{"mapped address", "[::ffff:192.0.2.7]:8080", []string{"::ffff:198.51.100.8"}, "198.51.100.8"},
		{"missing header", "192.0.2.7:8080", nil, "192.0.2.7"},
		{"malformed last address", "192.0.2.7:8080", []string{"203.0.113.1, 198.51.100.8:8080"}, "192.0.2.7"},
		{"empty last address", "192.0.2.7:8080", []string{"203.0.113.1", ""}, "192.0.2.7"},
		{"untrusted IPv4 neighbor", "203.0.113.2:8080", []string{"198.51.100.8"}, "203.0.113.2"},
		{"untrusted IPv6 neighbor", "[2001:db8:2::2]:8080", []string{"198.51.100.8"}, "2001:db8:2::2"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest("POST", "/api/login", nil)
			req.RemoteAddr = tc.peer
			for _, value := range tc.forwarded {
				req.Header.Add("X-Forwarded-For", value)
			}
			if got := limiter.clientAddress(req); got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestLoginLimitsIPv6Prefix(t *testing.T) {
	limiter := loginLimiter{trustedProxies: parseTrustedProxies("192.0.2.0/24")}
	req := httptest.NewRequest("POST", "/api/login", nil)
	req.RemoteAddr = "192.0.2.7:8080"
	for i := range loginAddressLimit {
		req.Header.Set("X-Forwarded-For", fmt.Sprintf("2001:db8:1:2::%x", i+1))
		finish, wait := limiter.start(req)
		if wait != 0 {
			t.Fatalf("unexpected limit at %d failures", i)
		}
		finish(true)
	}
	req.Header.Set("X-Forwarded-For", "2001:db8:1:2::ffff")
	if _, wait := limiter.start(req); wait <= 0 {
		t.Fatal("another address from that /64 bypassed the limit")
	}
	req.Header.Set("X-Forwarded-For", "2001:db8:1:3::1")
	if finish, wait := limiter.start(req); wait != 0 {
		t.Fatal("another /64 was unexpectedly limited")
	} else {
		finish(false)
	}
}

func TestLoginGlobalDailyLimit(t *testing.T) {
	var limiter loginLimiter
	for range loginDayLimit {
		limiter.day.failures = append(limiter.day.failures, time.Now().Add(-2*time.Hour))
	}
	if _, wait := limiter.start(httptest.NewRequest("POST", "/api/login", nil)); wait < 21*time.Hour {
		t.Fatalf("retry after %s, want about 22 hours", wait)
	}
}
