package main

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestDeviceCommands(t *testing.T) {
	s := integrationStore(t)
	ctx := t.Context()
	if err := s.setPassword(ctx, "listener", "fixture password"); err != nil {
		t.Fatal(err)
	}
	handler := newAPI(s, nil).routes()
	type loginResult struct {
		Token string `json:"token"`
		ID    int64  `json:"device_id"`
	}
	login := func(name string) loginResult {
		t.Helper()
		body, err := json.Marshal(map[string]string{"username": "listener", "password": "fixture password", "device_name": name})
		if err != nil {
			t.Fatal(err)
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, httptest.NewRequest("POST", "/api/login", bytes.NewReader(body)))
		if w.Code != 200 {
			t.Fatalf("login returned HTTP %d", w.Code)
		}
		return response[loginResult](t, w)
	}
	checkAccess := func(token string, want int) {
		t.Helper()
		req := httptest.NewRequest("GET", "/api/state", nil)
		req.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		if w.Code != want {
			t.Fatalf("access returned HTTP %d, want %d", w.Code, want)
		}
	}

	const firstName = "Reader\tA\n"
	first, second := login(firstName), login("Kitchen speaker")
	created := time.Date(2025, 10, 1, 8, 10, 0, 123_000_000, time.UTC)
	testExec(t, s.db, "UPDATE devices SET created_at = $2, last_seen_at = $2 WHERE id = $1", first.ID, created)
	checkAccess(first.Token, 200)

	var out bytes.Buffer
	if err := devicesCommand(ctx, s, []string{"list"}, &out); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(out.String(), "\n"), "\n")
	if strings.Contains(out.String(), first.Token) || strings.Contains(out.String(), second.Token) {
		t.Fatal("device list exposed a token")
	}
	if len(lines) != 3 || lines[0] != "ID\tDEVICE NAME\tCREATED\tLAST SEEN" {
		t.Fatal("device list did not return two rows with a header")
	}
	fields := strings.Split(lines[1], "\t")
	if len(fields) != 4 || fields[0] != strconv.FormatInt(first.ID, 10) ||
		fields[1] != strconv.Quote(firstName) || fields[2] != created.Format(timestampLayout) {
		t.Fatal("wrong device id, name, or creation time")
	}
	seen, err := time.Parse(timestampLayout, fields[3])
	if err != nil || !seen.After(created) {
		t.Fatal("authenticated request did not advance last seen")
	}
	fields = strings.Split(lines[2], "\t")
	if len(fields) != 4 || fields[0] != strconv.FormatInt(second.ID, 10) ||
		fields[1] != `"Kitchen speaker"` || fields[2] == "-" || fields[2] != fields[3] {
		t.Fatal("new login did not set creation and last seen times")
	}

	revoke := []string{"revoke", strconv.FormatInt(first.ID, 10)}
	if err := devicesCommand(ctx, s, revoke, &out); err != nil {
		t.Fatal(err)
	}
	checkAccess(first.Token, 401)
	checkAccess(second.Token, 200)
	if err := devicesCommand(ctx, s, revoke, &out); err == nil {
		t.Fatal("revoking an unknown device succeeded")
	}
	if err := devicesCommand(ctx, s, []string{"revoke", "-1"}, &out); err == nil {
		t.Fatal("invalid device id was accepted")
	}
	out.Reset()
	if err := devicesCommand(ctx, s, []string{"list"}, &out); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out.String(), strconv.Quote(firstName)) || !strings.Contains(out.String(), `"Kitchen speaker"`) {
		t.Fatal("device list did not reflect revocation")
	}
	third := login("Desk speaker")
	t.Setenv("EASYPODCAST_DATABASE_URL", testDatabaseURL(t, s.db).String())
	for range 2 {
		if err := run(ctx, []string{"devices", "revoke", "--all"}); err != nil {
			t.Fatal(err)
		}
	}
	checkAccess(second.Token, 401)
	checkAccess(third.Token, 401)
	if devices, err := s.devices(ctx); err != nil || len(devices) != 0 {
		t.Fatalf("devices remained after revoke --all: %d, %v", len(devices), err)
	}
}
