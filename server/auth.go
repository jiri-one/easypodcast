package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"net"
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
	err = s.db.QueryRow(ctx, "SELECT id FROM devices WHERE token_hash = $1", hash[:]).Scan(&id)
	return id, err
}

type loginWindow struct {
	failures []time.Time
	active   int
}

type loginLimiter struct {
	mu          sync.Mutex
	addresses   map[string]*loginWindow
	lastCleanup time.Time
}

func (l *loginLimiter) start(remote string) (func(bool), bool) {
	address, _, err := net.SplitHostPort(remote)
	if err != nil {
		address = remote
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
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
	window.expire(cutoff)
	if len(window.failures)+window.active >= 5 {
		return nil, false
	}
	window.active++
	return func(failed bool) {
		l.mu.Lock()
		defer l.mu.Unlock()
		window.active--
		if failed {
			window.failures = append(window.failures, time.Now())
		}
	}, true
}

func (w *loginWindow) expire(cutoff time.Time) {
	for len(w.failures) > 0 && !w.failures[0].After(cutoff) {
		w.failures = w.failures[1:]
	}
}
