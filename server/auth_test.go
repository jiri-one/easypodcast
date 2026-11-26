package main

import (
	"net/http/httptest"
	"testing"
)

func TestTrustedProxyAddress(t *testing.T) {
	limiter := loginLimiter{trustedProxies: parseTrustedProxies(" , 192.0.2.7/32, 2001:db8::/32, 203.0.113.1")}
	for _, tc := range []struct {
		name      string
		peer      string
		forwarded []string
		want      string
	}{
		{"trusted IPv4", "192.0.2.7:8080", []string{"203.0.113.1, 198.51.100.8 "}, "198.51.100.8"},
		{"trusted IPv6", "[2001:db8::7]:8080", []string{"203.0.113.1", "2001:0db8:1::8"}, "2001:db8:1::8"},
		{"mapped address", "[::ffff:192.0.2.7]:8080", []string{"::ffff:198.51.100.8"}, "198.51.100.8"},
		{"missing header", "192.0.2.7:8080", nil, "192.0.2.7"},
		{"malformed last address", "192.0.2.7:8080", []string{"203.0.113.1, 198.51.100.8:8080"}, "192.0.2.7"},
		{"empty last address", "192.0.2.7:8080", []string{"203.0.113.1", ""}, "192.0.2.7"},
		{"untrusted peer", "203.0.113.1:8080", []string{"198.51.100.8"}, "203.0.113.1"},
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
