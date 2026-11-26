package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"net"
	"net/http"
	"net/netip"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"golang.org/x/crypto/argon2"
)

const saltSize = 16
const hashSize = 32

func derivePassword(password string, salt []byte) []byte {
	return argon2.IDKey([]byte(password), salt, 3, 64*1024, 2, hashSize)
}

func (s store) setPassword(ctx context.Context, username, password string) error {
	if username == "" || password == "" {
		return errors.New("username and password must be nonempty")
	}
	salt := make([]byte, saltSize)
	_, _ = rand.Read(salt)
	hash := append(salt, derivePassword(password, salt)...)
	_, err := s.db.Exec(ctx, `INSERT INTO users (username, password_hash) VALUES ($1,$2)
		ON CONFLICT (username) DO UPDATE SET password_hash = EXCLUDED.password_hash`, username, hash)
	var dbErr interface{ SQLState() string }
	if errors.As(err, &dbErr) && dbErr.SQLState() == "23505" {
		return errors.New("this database already has a different user")
	}
	if err != nil {
		return errors.New("could not set password")
	}
	return nil
}

func (s store) verifyPassword(ctx context.Context, username, password string) (bool, error) {
	var stored []byte
	err := s.db.QueryRow(ctx, "SELECT password_hash FROM users WHERE username = $1", username).Scan(&stored)
	missing := errors.Is(err, pgx.ErrNoRows)
	if err != nil && !missing {
		return false, err
	}
	if missing {
		stored = make([]byte, saltSize+hashSize)
	}
	if len(stored) != saltSize+hashSize {
		return false, errors.New("invalid stored password hash")
	}
	match := subtle.ConstantTimeCompare(derivePassword(password, stored[:saltSize]), stored[saltSize:])
	return match == 1 && !missing, nil
}

func (s store) createDevice(ctx context.Context, username, name string) (string, int64, error) {
	raw := make([]byte, 32)
	_, _ = rand.Read(raw)
	hash := sha256.Sum256(raw)
	var id int64
	err := s.db.QueryRow(ctx, "INSERT INTO devices (username, name, token_hash) VALUES ($1,$2,$3) RETURNING id",
		username, name, hash[:]).Scan(&id)
	return base64.RawURLEncoding.EncodeToString(raw), id, err
}

func (s store) deviceID(ctx context.Context, token string) (int64, error) {
	raw, err := base64.RawURLEncoding.Strict().DecodeString(token)
	if err != nil || len(raw) != 32 {
		return 0, pgx.ErrNoRows
	}
	hash := sha256.Sum256(raw)
	var id int64
	err = s.db.QueryRow(ctx, `WITH touched AS (
			UPDATE devices SET last_seen_at = now() WHERE token_hash = $1
				AND (last_seen_at IS NULL OR last_seen_at <= now() - interval '5 minutes') RETURNING id
		)
		SELECT id FROM touched UNION ALL
		SELECT id FROM devices WHERE token_hash = $1 AND NOT EXISTS (SELECT 1 FROM touched)`, hash[:]).Scan(&id)
	return id, err
}

type loginWindow struct {
	failures []time.Time
	active   int
}

type loginLimiter struct {
	trustedProxies []*net.IPNet
	mu             sync.Mutex
	addresses      map[string]*loginWindow
	lastCleanup    time.Time
	minute         loginWindow
	day            loginWindow
}

const (
	loginAddressLimit = 5
	loginMinuteLimit  = 20
	loginDayLimit     = 200
)

func parseTrustedProxies(value string) []*net.IPNet {
	var networks []*net.IPNet
	for part := range strings.SplitSeq(value, ",") {
		part = strings.TrimSpace(part)
		if _, network, err := net.ParseCIDR(part); err == nil {
			networks = append(networks, network)
		} else if ip := net.ParseIP(part); ip != nil {
			bits := net.IPv6len * 8
			if ip.To4() != nil {
				bits = net.IPv4len * 8
			}
			networks = append(networks, &net.IPNet{IP: ip, Mask: net.CIDRMask(bits, bits)})
		}
	}
	return networks
}

func (l *loginLimiter) clientAddress(r *http.Request) string {
	address, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		address = r.RemoteAddr
	}
	peer, err := netip.ParseAddr(address)
	if err != nil {
		return address
	}
	peer = peer.WithZone("").Unmap()
	if !l.trustsProxy(peer) {
		return peer.String()
	}
	for _, field := range slices.Backward(r.Header.Values("X-Forwarded-For")) {
		for _, part := range slices.Backward(strings.Split(field, ",")) {
			client, err := netip.ParseAddr(strings.TrimSpace(part))
			if err != nil || client.Zone() != "" {
				return peer.String()
			}
			client = client.Unmap()
			if !l.trustsProxy(client) {
				return client.String()
			}
		}
	}
	return peer.String()
}

func (l *loginLimiter) trustsProxy(ip netip.Addr) bool {
	for _, network := range l.trustedProxies {
		if network.Contains(ip.AsSlice()) {
			return true
		}
	}
	return false
}

func (l *loginLimiter) start(r *http.Request) (func(bool), time.Duration) {
	address := l.clientAddress(r)
	if ip, err := netip.ParseAddr(address); err == nil && ip.Is6() {
		prefix, _ := ip.Prefix(64)
		address = prefix.String()
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	wait := max(l.minute.retryAfter(now, time.Minute, loginMinuteLimit), l.day.retryAfter(now, 24*time.Hour, loginDayLimit))
	if wait > 0 {
		return nil, wait
	}
	cutoff := now.Add(-time.Minute)
	if l.addresses == nil {
		l.addresses = make(map[string]*loginWindow)
	}
	if now.Sub(l.lastCleanup) >= time.Minute {
		for key, window := range l.addresses {
			window.expire(cutoff)
			if len(window.failures) == 0 && window.active == 0 {
				delete(l.addresses, key)
			}
		}
		l.lastCleanup = now
	}
	window := l.addresses[address]
	if window == nil {
		window = &loginWindow{}
		l.addresses[address] = window
	}
	if wait := window.retryAfter(now, time.Minute, loginAddressLimit); wait > 0 {
		return nil, wait
	}
	windows := [3]*loginWindow{window, &l.minute, &l.day}
	for _, w := range windows {
		w.active++
	}
	return func(failed bool) {
		l.mu.Lock()
		defer l.mu.Unlock()
		now := time.Now()
		for _, w := range windows {
			w.active--
			if failed {
				w.failures = append(w.failures, now)
			}
		}
	}, 0
}

func (w *loginWindow) retryAfter(now time.Time, interval time.Duration, limit int) time.Duration {
	w.expire(now.Add(-interval))
	if len(w.failures)+w.active < limit {
		return 0
	}
	if len(w.failures) < limit {
		return time.Second
	}
	return w.failures[len(w.failures)-limit].Add(interval).Sub(now)
}

func (w *loginWindow) expire(cutoff time.Time) {
	for len(w.failures) > 0 && !w.failures[0].After(cutoff) {
		w.failures = w.failures[1:]
	}
}
