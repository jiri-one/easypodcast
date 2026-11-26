package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func testRSS(items ...string) string {
	return "<rss><channel><title>Fixture</title>" + strings.Join(items, "") + "</channel></rss>"
}

func testRSSItem(guid, title, date, file string) string {
	return fmt.Sprintf(`<item><guid>%s</guid><title>%s</title><pubDate>%s</pubDate><enclosure url="%s"/></item>`,
		guid, title, date, file)
}

func TestRefreshRejectsLimitedFeedWithoutChangingHistory(t *testing.T) {
	t.Setenv("EASYPODCAST_ALLOW_PRIVATE_FEEDS", "true")
	s := integrationStore(t)
	var mode atomic.Int32
	initial := testRSS(testRSSItem("existing", "Original episode", "", "/original.mp3"))
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		switch mode.Load() {
		case 1:
			_, _ = io.WriteString(w, testRSS(strings.Repeat("<item/>", maxFeedItems+1)))
		case 2:
			_, _ = io.WriteString(w, testRSS(strings.Repeat("<box>", maxFeedDepth)+strings.Repeat("</box>", maxFeedDepth)))
		case 3:
			_, _ = io.WriteString(w, testRSS(testRSSItem("new", "New episode", "", "/new.mp3")))
		case 4:
			_, _ = io.WriteString(w, `{"title":"Fixture\u0000","items":[]}`)
		default:
			_, _ = io.WriteString(w, initial)
		}
	}))
	defer bad.Close()
	good := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		_, _ = io.WriteString(w, testRSS(testRSSItem("good", fmt.Sprintf("Revision %d", mode.Load()), "", "/good.mp3")))
	}))
	defer good.Close()
	r := newRefresher(s, "EasyPodcast/test", time.Hour)
	p, _, err := r.subscribe(t.Context(), bad.URL)
	if err != nil {
		t.Fatal(err)
	}
	other, _, err := r.subscribe(t.Context(), good.URL)
	if err != nil {
		t.Fatal(err)
	}
	episodes, err := s.episodes(t.Context(), p.ID)
	if err != nil || len(episodes) != 1 {
		t.Fatalf("initial episodes: %+v, %v", episodes, err)
	}
	id := episodes[0].ID
	now := time.Now()
	if _, err := s.updateState(t.Context(), stateChange{
		Episodes: []episodeState{{EpisodeID: id, Status: "played", UpdatedAt: timestamp{now}}},
	}, now); err != nil {
		t.Fatal(err)
	}
	episodeCount := int64(1)
	for i, want := range []feedError{errTooManyItems, errFeedTooDeep, errStoredEpisodeLimit, errUnusableFeed} {
		if want == errStoredEpisodeLimit {
			testExec(t, s.db, `INSERT INTO episodes (podcast_id, guid, title, enclosure_url, removed_from_feed, description)
				SELECT $1, '', 'Archived episode', '/archive/' || n, true, ''
				FROM generate_series(1,$2::integer) n`, p.ID, maxStoredFeedEpisodes-1)
			episodeCount = maxStoredFeedEpisodes
		}
		mode.Store(int32(i + 1))
		r.refreshDue(t.Context(), true)
		row, err := s.podcast(t.Context(), p.ID)
		if err != nil || row.LastError == nil || *row.LastError != want.Error() ||
			row.EpisodesVersion != p.EpisodesVersion || row.EpisodeCount != episodeCount || row.PlayedCount != 1 {
			t.Fatalf("rejected feed: %+v, %v", row, err)
		}
		episode, err := s.episode(t.Context(), id)
		if err != nil || episode.Title != "Original episode" || episode.RemovedFromFeed {
			t.Fatalf("stored episode changed: %+v, %v", episode, err)
		}
		episodes, err := s.episodes(t.Context(), other.ID)
		if err != nil || len(episodes) != 1 || episodes[0].Title != fmt.Sprintf("Revision %d", i+1) {
			t.Fatalf("other feed did not refresh: %+v, %v", episodes, err)
		}
	}
}

func TestIdenticalGUIDAndEnclosureKeepsEpisodeState(t *testing.T) {
	t.Setenv("EASYPODCAST_ALLOW_PRIVATE_FEEDS", "true")
	s := integrationStore(t)
	var body atomic.Value
	first := testRSSItem("same", "Episode", "", "/original.mp3")
	body.Store(testRSS(first))
	feed := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, body.Load().(string))
	}))
	defer feed.Close()
	r := newRefresher(s, "EasyPodcast/test", time.Hour)
	p, _, err := r.subscribe(t.Context(), feed.URL)
	if err != nil {
		t.Fatal(err)
	}
	episodes, err := s.episodes(t.Context(), p.ID)
	if err != nil || len(episodes) != 1 {
		t.Fatalf("initial episodes: %+v, %v", episodes, err)
	}
	id := episodes[0].ID
	now := time.Now()
	if _, err := s.updateState(t.Context(), stateChange{
		Episodes: []episodeState{{EpisodeID: id, PositionMS: 1_200_000, UpdatedAt: timestamp{now}}},
	}, now); err != nil {
		t.Fatal(err)
	}
	body.Store(testRSS(first, first))
	r.refreshDue(t.Context(), true)
	body.Store(testRSS(testRSSItem("same", "Episode", "", "/new-cdn.mp3")))
	r.refreshDue(t.Context(), true)
	episodes, err = s.episodes(t.Context(), p.ID)
	if err != nil || len(episodes) != 1 || episodes[0].ID != id || episodes[0].GUID != "same" ||
		episodes[0].RemovedFromFeed || episodes[0].EnclosureURL != feed.URL+"/new-cdn.mp3" {
		t.Fatalf("duplicate item changed episode identity: %+v, %v", episodes, err)
	}
	state, err := s.episodeState(t.Context(), id)
	if err != nil || state == nil || state.PositionMS != 1_200_000 {
		t.Fatalf("episode lost its state: %+v, %v", state, err)
	}
}

func TestDuplicateGUIDsPreserveEpisodeIdentity(t *testing.T) {
	t.Setenv("EASYPODCAST_ALLOW_PRIVATE_FEEDS", "true")
	for _, newestFirst := range []bool{true, false} {
		t.Run(fmt.Sprintf("newest first %t", newestFirst), func(t *testing.T) {
			s := integrationStore(t)
			first := testRSSItem("shared", "First", "", "/first.mp3")
			second := testRSSItem("shared", "Second", "", "/second.mp3")
			var body atomic.Value
			body.Store(testRSS(first))
			feed := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				_, _ = io.WriteString(w, body.Load().(string))
			}))
			defer feed.Close()
			r := newRefresher(s, "EasyPodcast/test", time.Hour)
			p, _, err := r.subscribe(t.Context(), feed.URL)
			if err != nil {
				t.Fatal(err)
			}
			episodes, err := s.episodes(t.Context(), p.ID)
			if err != nil || len(episodes) != 1 {
				t.Fatalf("initial episodes %+v, %v", episodes, err)
			}
			firstID := episodes[0].ID
			now := time.Now()
			if _, err := s.updateState(t.Context(), stateChange{
				Episodes: []episodeState{{EpisodeID: firstID, PositionMS: 1_200_000, UpdatedAt: timestamp{now}}},
			}, now); err != nil {
				t.Fatal(err)
			}
			if newestFirst {
				body.Store(testRSS(second, first))
			} else {
				body.Store(testRSS(first, second))
			}
			r.refreshDue(t.Context(), true)
			episodes, err = s.episodes(t.Context(), p.ID)
			if err != nil || len(episodes) != 2 {
				t.Fatalf("episodes with repeated GUID %+v, %v", episodes, err)
			}
			secondID := int64(0)
			for _, e := range episodes {
				if e.Title == "Second" {
					secondID = e.ID
				}
			}
			if secondID == firstID || secondID == 0 {
				t.Fatalf("second episode replaced the first: %+v", episodes)
			}
			dest, added, err := s.matchPineEpisodes(t.Context(), map[int64][]pineEpisode{
				p.ID: {
					{ID: 101, GUID: "shared", EnclosureURL: feed.URL + "/first.mp3"},
					{ID: 102, GUID: "shared", EnclosureURL: feed.URL + "/second.mp3"},
				},
			})
			if err != nil || added != 0 || dest[101] != firstID || dest[102] != secondID {
				t.Fatalf("PinePods GUID matches %v, added %d, %v", dest, added, err)
			}

			body.Store(testRSS(second))
			r.refreshDue(t.Context(), true)
			original, err := s.episode(t.Context(), firstID)
			if err != nil || original.Title != "First" || original.EnclosureURL != feed.URL+"/first.mp3" ||
				!original.RemovedFromFeed {
				t.Fatalf("first episode after duplicate left: %+v, %v", original, err)
			}
			current, err := s.episode(t.Context(), secondID)
			if err != nil || current.Title != "Second" || current.RemovedFromFeed {
				t.Fatalf("second episode after duplicate left: %+v, %v", current, err)
			}
			state, err := s.episodeState(t.Context(), firstID)
			if err != nil || state == nil || state.PositionMS != 1_200_000 {
				t.Fatalf("original playback state %+v, %v", state, err)
			}
			state, err = s.episodeState(t.Context(), secondID)
			if err != nil || state != nil {
				t.Fatalf("second episode inherited state %+v, %v", state, err)
			}
		})
	}
}

func TestUndatedFeedItemsKeepOrder(t *testing.T) {
	t.Setenv("EASYPODCAST_ALLOW_PRIVATE_FEEDS", "true")
	latest := testRSSItem("latest", "Latest", "some Tuesday", "/latest.mp3")
	recent := testRSSItem("recent", "Recent", "26 Nov 26 09:15 GMT", "/recent.mp3")
	older := testRSSItem("older", "Older", "25 Nov 26 09:15 GMT", "/older.mp3")
	trailer := testRSSItem("trailer", "Trailer", "", "/trailer.mp3")
	for _, tc := range []struct {
		name, initial, updated string
		firstOrder, nextOrder  []string
	}{
		{"no dates", testRSS(latest, trailer), testRSS(latest, trailer),
			[]string{"Latest", "Trailer"}, []string{"Latest", "Trailer"}},
		{"some dates", testRSS(recent, older), testRSS(latest, recent, older, trailer),
			[]string{"Recent", "Older"}, []string{"Latest", "Recent", "Older", "Trailer"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := integrationStore(t)
			var updated atomic.Bool
			feed := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				if updated.Load() {
					_, _ = io.WriteString(w, tc.updated)
				} else {
					_, _ = io.WriteString(w, tc.initial)
				}
			}))
			defer feed.Close()
			r := newRefresher(s, "EasyPodcast/test", time.Hour)
			p, _, err := r.subscribe(t.Context(), feed.URL)
			if err != nil {
				t.Fatal(err)
			}
			expectOrder := func(want []string) {
				t.Helper()
				episodes, err := s.episodes(t.Context(), p.ID)
				if err != nil {
					t.Fatal(err)
				}
				titles := make([]string, 0, len(episodes))
				for _, e := range episodes {
					titles = append(titles, e.Title)
					if (e.Title == "Latest" || e.Title == "Trailer") && e.PublishedAt != nil {
						t.Fatalf("an estimated date appeared in the API: %+v", e)
					}
				}
				if !slices.Equal(titles, want) {
					t.Fatalf("episode order %v, want %v", titles, want)
				}
			}
			expectOrder(tc.firstOrder)
			updated.Store(true)
			r.refreshDue(t.Context(), true)
			expectOrder(tc.nextOrder)
			if tc.initial == tc.updated {
				again, err := s.podcast(t.Context(), p.ID)
				if err != nil || again.EpisodesVersion != p.EpisodesVersion {
					t.Fatalf("unchanged feed changed version: %+v, %v", again, err)
				}
			}
		})
	}
}

func TestFeedOrderChangesWithoutRewritingEpisodes(t *testing.T) {
	t.Setenv("EASYPODCAST_ALLOW_PRIVATE_FEEDS", "true")
	for _, date := range []string{"", "26 Nov 26 09:15 GMT"} {
		t.Run("published="+date, func(t *testing.T) {
			s := integrationStore(t)
			item := func(i int) string {
				return testRSSItem(fmt.Sprint(i), fmt.Sprint(i), date, fmt.Sprintf("/%d.mp3", i))
			}
			items := make([]string, 128)
			for i := range items {
				items[i] = item(i)
			}
			var body atomic.Value
			body.Store(testRSS(items...))
			feed := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				_, _ = io.WriteString(w, body.Load().(string))
			}))
			defer feed.Close()
			r := newRefresher(s, "EasyPodcast/test", time.Hour)
			p, _, err := r.subscribe(t.Context(), feed.URL)
			if err != nil {
				t.Fatal(err)
			}
			var previousXID string
			if err := s.db.QueryRow(t.Context(), "SELECT xmin::text FROM episodes WHERE podcast_id = $1 LIMIT 1", p.ID).Scan(&previousXID); err != nil {
				t.Fatal(err)
			}
			var previousVersion = p.EpisodesVersion
			for added, input := range [][]string{
				append([]string{item(128)}, items...),
				append([]string{item(127), item(128)}, items[:127]...),
			} {
				body.Store(testRSS(input...))
				r.refreshDue(t.Context(), true)
				current, err := s.podcast(t.Context(), p.ID)
				if err != nil || current.EpisodesVersion == previousVersion || current.LastError != nil {
					t.Fatalf("episode order change did not update the version: %+v, %v", current, err)
				}
				previousVersion = current.EpisodesVersion
				var unchanged int
				if err := s.db.QueryRow(t.Context(), "SELECT count(*) FROM episodes WHERE podcast_id = $1 AND xmin::text = $2",
					p.ID, previousXID).Scan(&unchanged); err != nil || unchanged != len(items) {
					t.Fatalf("%d of %d existing rows left untouched: %v", unchanged, len(items), err)
				}
				ordered, err := s.episodes(t.Context(), p.ID)
				if err != nil || len(ordered) != len(input) || ordered[0].GUID != fmt.Sprint(128-added) {
					t.Fatalf("unexpected episode order after refresh: %v", err)
				}
			}
		})
	}
}

func TestCanceledRefreshRestoresSchedule(t *testing.T) {
	for _, superseded := range []bool{false, true} {
		t.Run(fmt.Sprintf("superseded=%t", superseded), func(t *testing.T) {
			s := integrationStore(t)
			testExec(t, s.db, `INSERT INTO podcasts (feed_url, failures, last_error, next_refresh_at)
				VALUES ('https://feed.invalid', 2, 'earlier failure', now() + interval '1 hour')`)
			r := newRefresher(s, "EasyPodcast/test", time.Hour)
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			entered := make(chan struct{})
			r.client.Transport = feedRoundTripFunc(func(req *http.Request) (*http.Response, error) {
				close(entered)
				<-req.Context().Done()
				return nil, req.Context().Err()
			})
			target, err := s.feedTarget(ctx, 1)
			if err != nil {
				t.Fatal(err)
			}
			done := make(chan error, 1)
			go func() { done <- r.refresh(ctx, target) }()
			select {
			case <-entered:
			case err := <-done:
				t.Fatalf("refresh ended before fetching: %v", err)
			case <-time.After(5 * time.Second):
				t.Fatal("refresh never started")
			}
			type schedule struct {
				failures   int
				due        bool
				lastError  string
				generation int64
			}
			read := func() schedule {
				t.Helper()
				var state schedule
				if err := s.db.QueryRow(t.Context(), `SELECT failures, next_refresh_at <= now(), last_error,
					fetch_generation FROM podcasts WHERE id = 1`).
					Scan(&state.failures, &state.due, &state.lastError, &state.generation); err != nil {
					t.Fatal(err)
				}
				return state
			}
			if got := read(); got != (schedule{3, false, "earlier failure", target.Generation}) {
				t.Fatalf("refresh had no crash guard: %+v", got)
			}
			want := schedule{2, true, "earlier failure", target.Generation}
			if superseded {
				testExec(t, s.db, `UPDATE podcasts SET failures = 0, last_error = 'newer result',
					next_refresh_at = now() + interval '1 hour', fetch_generation = fetch_generation + 1 WHERE id = 1`)
				want = schedule{0, false, "newer result", target.Generation + 1}
			}
			cancel()
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				t.Fatal("canceled refresh did not finish")
			}
			if got := read(); got != want {
				t.Fatalf("after cancellation: %+v, want %+v", got, want)
			}
		})
	}
}

func TestSubscribeHasSlotDuringBackgroundRefresh(t *testing.T) {
	s := integrationStore(t)
	testExec(t, s.db, `INSERT INTO podcasts (feed_url)
		SELECT 'https://feed.invalid/slow/' || n FROM generate_series(1,4) n`)
	r := newRefresher(s, "EasyPodcast/test", time.Hour)
	entered := make(chan struct{}, 4)
	r.client.Transport = feedRoundTripFunc(func(req *http.Request) (*http.Response, error) {
		if strings.HasPrefix(req.URL.Path, "/slow/") {
			entered <- struct{}{}
			<-req.Context().Done()
			return nil, req.Context().Err()
		}
		return &http.Response{
			StatusCode: http.StatusOK, Request: req,
			Body: io.NopCloser(strings.NewReader(testRSS(testRSSItem("healthy", "Healthy", "", "/healthy.mp3")))),
		}, nil
	})
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan struct{})
	go func() { r.refreshDue(ctx, false); close(done) }()
	defer func() { cancel(); <-done }()
	wait := time.After(5 * time.Second)
	for range 3 {
		select {
		case <-entered:
		case <-wait:
			t.Fatal("background workers did not start")
		}
	}
	select {
	case <-entered:
		t.Fatal("background refresh used the reserved slot")
	case <-time.After(100 * time.Millisecond):
	}
	request, stop := context.WithTimeout(t.Context(), 3*time.Second)
	defer stop()
	if p, added, err := r.subscribe(request, "https://feed.invalid/healthy"); err != nil || !added || p.EpisodeCount != 1 {
		t.Fatalf("healthy feed was blocked by background fetches: %+v, %v", p, err)
	}
}

func TestFeedWritersLeaveConnectionsForAPI(t *testing.T) {
	base := integrationStore(t)
	cfg := base.db.Config()
	cfg.MaxConns, cfg.MinConns, cfg.MinIdleConns = 4, 0, 0
	pool, err := pgxpool.NewWithConfig(t.Context(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	s := newStore(pool)
	entered := make(chan struct{})
	release := make(chan struct{})
	holder := make(chan error, 1)
	go func() {
		holder <- s.withFeedLock(t.Context(), func(pgx.Tx) error {
			close(entered)
			<-release
			return nil
		})
	}()
	select {
	case <-entered:
	case err := <-holder:
		t.Fatalf("could not hold feed lock: %v", err)
	case <-time.After(5 * time.Second):
		close(release)
		t.Fatal("timed out waiting for the feed lock")
	}
	defer func() {
		close(release)
		if err := <-holder; err != nil {
			t.Error(err)
		}
	}()
	before := pool.Stat().AcquireCount()
	ctx, cancel := context.WithTimeout(t.Context(), 200*time.Millisecond)
	defer cancel()
	waiters := make(chan error, 4)
	for i := range cap(waiters) {
		go func() {
			waiters <- s.applyRefresh(ctx, feedTarget{ID: int64(i + 1)}, feedResponse{}, time.Now())
		}()
	}
	for range cap(waiters) {
		if err := <-waiters; !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("waiting writer: %v", err)
		}
	}
	if acquired := pool.Stat().AcquireCount(); acquired != before {
		t.Fatalf("waiting writers acquired %d pool connections", acquired-before)
	}
	rec := httptest.NewRecorder()
	newAPI(s, nil).routes().ServeHTTP(rec, httptest.NewRequest("GET", "/health", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("health while feed write is active: HTTP %d", rec.Code)
	}
}

type feedRoundTripFunc func(*http.Request) (*http.Response, error)

func (fn feedRoundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return fn(r) }

func TestRefreshRecordsSafeFailureAndSchedulesBackoff(t *testing.T) {
	s := integrationStore(t)
	const address = "https://feed.invalid/show?token=fixture-secret"
	testExec(t, s.db, "INSERT INTO podcasts (feed_url) VALUES ($1)", address)
	r := newRefresher(s, "EasyPodcast/test", time.Hour)
	var logs bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&logs, nil)))
	defer slog.SetDefault(previous)
	r.client.Transport = feedRoundTripFunc(func(req *http.Request) (*http.Response, error) {
		var failures int
		var next time.Time
		err := s.db.QueryRow(req.Context(), "SELECT failures, next_refresh_at FROM podcasts WHERE id = 1").Scan(&failures, &next)
		if err != nil || failures != 1 || next.Before(time.Now().Add(time.Hour)) {
			t.Errorf("fetch started without recorded backoff: %d, %s, %v", failures, next, err)
		}
		return nil, &net.OpError{Op: "dial", Net: "tcp", Err: syscall.ECONNREFUSED}
	})
	r.refreshDue(t.Context(), false)
	p, err := s.podcast(t.Context(), 1)
	if err != nil || p.LastError == nil || *p.LastError != "feed connection refused" {
		t.Fatalf("last_error %+v, %v", p.LastError, err)
	}
	if log := logs.String(); strings.Contains(log, "fixture-secret") || !strings.Contains(log, "feed connection refused") {
		t.Fatalf("unexpected log %s", log)
	}
}

func TestFeedTransportErrors(t *testing.T) {
	for _, tc := range []struct {
		err  error
		want feedError
	}{
		{context.DeadlineExceeded, errFeedTimeout},
		{&net.DNSError{IsNotFound: true}, "feed host not found"},
		{&net.DNSError{}, "feed DNS lookup failed"},
		{syscall.ECONNRESET, "feed connection reset"},
		{errInvalidRedirect, errInvalidRedirect},
		{io.ErrUnexpectedEOF, "could not read feed"},
	} {
		err := &url.Error{Op: "Get", URL: "https://feed.invalid/?token=fixture-secret", Err: tc.err}
		if got := feedTransportError(err, "could not read feed"); got != tc.want {
			t.Errorf("for %T got %q, want %q", tc.err, got, tc.want)
		}
	}
}
