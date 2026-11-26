package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"reflect"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func pineTestSource(t *testing.T) (*pgxpool.Pool, *pgx.Conn) {
	t.Helper()
	source := isolatedSchema(t)
	testExec(t, source, `
		CREATE TABLE "Users" (UserID int PRIMARY KEY, Username text UNIQUE);
		CREATE TABLE "Podcasts" (PodcastID int PRIMARY KEY, FeedID int, FeedURL text, UserID int, IsYouTubeChannel bool,
			PodcastName text, Author text, Description text, ArtworkURL text, WebsiteURL text);
		CREATE TABLE "Episodes" (
			EpisodeID int PRIMARY KEY, PodcastID int, FeedID int, EpisodeGUID text, EpisodeURL text,
			EpisodeTitle text, EpisodePubDate timestamp, EpisodeDuration int
		);
		CREATE TABLE "UserEpisodeHistory" (
			UserID int, EpisodeID int, ListenDate timestamp, ListenDuration int,
			PRIMARY KEY (UserID, EpisodeID)
		);
		CREATE TABLE "UserEpisodeState" (
			UserID int, EpisodeID int, Completed bool, CompletedAt timestamp,
			PRIMARY KEY (UserID, EpisodeID)
		);
		CREATE TABLE "EpisodeQueue" (QueueID int PRIMARY KEY, UserID int, EpisodeID int, QueuePosition int, Is_YouTube bool);
		INSERT INTO "Users" VALUES (1,'other'), (2,'fixture-listener');
	`)
	db, err := pgx.ConnectConfig(t.Context(), source.Config().ConnConfig)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close(context.Background()) })
	return source, db
}

func TestImportPinepods(t *testing.T) {
	t.Setenv("EASYPODCAST_ALLOW_PRIVATE_FEEDS", "true")
	source, db := pineTestSource(t)
	s := integrationStore(t)
	feed := fixture(t, "first.xml")
	website := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(feed)
	}))
	defer website.Close()

	testExec(t, source, `INSERT INTO "Podcasts" (PodcastID, FeedID, FeedURL, UserID, IsYouTubeChannel) VALUES
		(21, 7, $1, 2, false), (22, 8, 'broken', 2, true), (11, 7, $1, 1, false), (12, 9, 'foreign', 1, false)`,
		website.URL+"/feeds/cloudberry.xml")
	testExec(t, source, `INSERT INTO "Episodes" VALUES
		(1, 11, 7, 'cloudberry-copper', $1, 'Old copper title', NULL, 3300),
		(2, 21, NULL, 'old-paper-guid', $2, 'Old paper title', NULL, NULL),
		(3, 21, 7, 'missing-from-current-feed', $3, 'Obsidian Bell', '2025-09-20 11:12:13', 811),
		(4, 11, 7, NULL, $4, 'Quiet Archive', NULL, 0),
		(5, 12, 9, 'other-user-episode', $5, 'Distant Archive', NULL, NULL),
		(6, 21, 7, 'cloudberry-notice', '', 'Notice without recording', NULL, NULL),
		(7, 21, 7, 'invalid-enclosure', 'file:///local', 'Invalid enclosure', NULL, NULL)`,
		website.URL+"/outdated", website.URL+"/audio/paper.mp3", website.URL+"/obsidian.mp3",
		website.URL+"/quiet.mp3", website.URL+"/distant.mp3")
	testExec(t, source, `
		INSERT INTO "UserEpisodeHistory" VALUES
			(2,1,'2025-10-01 08:10:00.123',132),
			(2,2,'2025-10-01 08:22:00',20),
			(2,3,'2025-10-01 08:23:00',30),
			(1,1,'2025-10-02 09:00:00',999);
		INSERT INTO "UserEpisodeState" VALUES
			(2,2,true,'2025-10-01 08:20:00.456'),
			(2,3,true,'2025-10-01 08:24:00.789'),
			(1,1,true,'2025-10-02 09:00:00');
		INSERT INTO "EpisodeQueue" VALUES
			(100,2,1,30,false), (101,2,2,10,false), (102,2,3,20,false), (103,2,1,1,true), (104,2,9,25,false);
	`)
	r := newRefresher(s, "EasyPodcast/test", time.Hour)
	start := time.Now()
	result, err := r.importPinepods(t.Context(), db, "fixture-listener")
	if err != nil {
		t.Fatal(err)
	}
	if want := (pineSummary{
		added: 1, matchedPositions: 1, matchedCompletions: 2, queueEntries: 3,
		removedEpisodesAdded: 2, unmatchedEpisodes: 3, unmatchedQueueEntries: 1,
	}); result != want {
		t.Fatalf("summary %+v, want %+v", result, want)
	}
	podcasts, err := s.podcasts(t.Context(), false)
	if err != nil || len(podcasts) != 1 || podcasts[0].EpisodeCount != 4 || podcasts[0].PlayedCount != 2 {
		t.Fatalf("podcasts %+v, %v", podcasts, err)
	}
	episodes, err := s.episodes(t.Context(), podcasts[0].ID)
	if err != nil || len(episodes) != 4 {
		t.Fatalf("episodes %+v, %v", episodes, err)
	}
	byTitle := make(map[string]episode)
	for _, e := range episodes {
		byTitle[e.Title] = e
	}
	copper, paper := byTitle["Copper Kite"].ID, byTitle["Paper Cloud"].ID
	if copper == 0 || paper == 0 || byTitle["Copper Kite"].EnclosureURL != website.URL+"/feeds/audio/copper.mp3" {
		t.Fatal("PinePods metadata replaced current feed data")
	}
	archived := byTitle["Obsidian Bell"]
	published := time.Date(2025, 9, 20, 11, 12, 13, 0, time.UTC)
	if !archived.RemovedFromFeed || archived.GUID != "missing-from-current-feed" ||
		archived.EnclosureURL != website.URL+"/obsidian.mp3" || archived.PublishedAt == nil ||
		!archived.PublishedAt.Equal(published) || archived.DurationSeconds == nil || *archived.DurationSeconds != 811 {
		t.Fatalf("removed episode metadata %+v", archived)
	}
	if untouched := byTitle["Quiet Archive"]; !untouched.RemovedFromFeed || untouched.GUID != "" ||
		untouched.EnclosureURL != website.URL+"/quiet.mp3" || untouched.DurationSeconds != nil || untouched.PublishedAt != nil {
		t.Fatalf("removed episode without listening history %+v", untouched)
	}
	ids, err := s.searchEpisodes(t.Context(), &podcasts[0].ID, []string{"obsidian", "bell"})
	if err != nil || !slices.Equal(ids, []int64{archived.ID}) {
		t.Fatalf("archived PinePods episode search: %v, %v", ids, err)
	}
	listenAt := time.Date(2025, 10, 1, 8, 10, 0, 123_000_000, time.UTC)
	doneAt := time.Date(2025, 10, 1, 8, 20, 0, 456_000_000, time.UTC)
	position, err := s.episodeState(t.Context(), copper)
	if err != nil || position == nil || position.PositionMS != 132000 || position.Status != "" ||
		position.DurationMS != nil || !position.UpdatedAt.Equal(listenAt) {
		t.Fatalf("position %+v, %v", position, err)
	}
	completed, err := s.episodeState(t.Context(), paper)
	if err != nil || completed == nil || completed.PositionMS != 0 || completed.Status != "played" || !completed.UpdatedAt.Equal(doneAt) {
		t.Fatalf("completion %+v, %v", completed, err)
	}
	archivedState, err := s.episodeState(t.Context(), archived.ID)
	if err != nil || archivedState == nil || archivedState.Status != "played" || archivedState.DurationMS != nil ||
		!archivedState.UpdatedAt.Equal(time.Date(2025, 10, 1, 8, 24, 0, 789_000_000, time.UTC)) {
		t.Fatalf("removed episode's completion %+v, %v", archivedState, err)
	}
	state, err := s.state(t.Context())
	if err != nil || state.Queue == nil || !slices.Equal(state.Queue.EpisodeIDs, []int64{paper, archived.ID, copper}) ||
		state.Queue.UpdatedAt.Before(start.Add(-time.Microsecond)) || state.Queue.UpdatedAt.After(time.Now()) {
		t.Fatalf("queue %+v, %v", state.Queue, err)
	}

	result, err = r.importPinepods(t.Context(), db, "fixture-listener")
	if err != nil || result.added != 0 || result.existing != 1 || result.removedEpisodesAdded != 0 || result.queueEntries != 0 {
		t.Fatalf("second import %+v, %v", result, err)
	}
	repeated, err := s.state(t.Context())
	if err != nil || !reflect.DeepEqual(state, repeated) {
		t.Fatalf("second import changed state or queue: %+v, %v", repeated, err)
	}
	repeatedEpisodes, err := s.episodes(t.Context(), podcasts[0].ID)
	if err != nil || !reflect.DeepEqual(episodes, repeatedEpisodes) {
		t.Fatalf("second import changed episode metadata or ids: %+v, %v", repeatedEpisodes, err)
	}
	repeatedPodcast, err := s.podcast(t.Context(), podcasts[0].ID)
	if err != nil || repeatedPodcast.EpisodesVersion != podcasts[0].EpisodesVersion || repeatedPodcast.PlayedCount != 2 {
		t.Fatalf("second import changed episode version or played count: %+v, %v", repeatedPodcast, err)
	}

	measured := int64(234567)
	newer := episodeState{
		EpisodeID: copper, PositionMS: 1800, DurationMS: &measured, UpdatedAt: timestamp{listenAt.Add(time.Hour)},
	}
	manualQueue := &queue{EpisodeIDs: []int64{copper}, UpdatedAt: timestamp{state.Queue.UpdatedAt.Add(time.Microsecond)}}
	change := stateChange{Episodes: []episodeState{newer}, Queue: manualQueue}
	if _, err := s.updateState(t.Context(), change, time.Now()); err != nil {
		t.Fatal(err)
	}
	result, err = r.importPinepods(t.Context(), db, "fixture-listener")
	if err != nil || result.removedEpisodesAdded != 0 || result.queueEntries != 0 {
		t.Fatalf("import after manual change %+v, %v", result, err)
	}
	preserved, err := s.episodeState(t.Context(), copper)
	if err != nil || preserved == nil || preserved.PositionMS != newer.PositionMS || !preserved.UpdatedAt.Equal(newer.UpdatedAt.Time) ||
		preserved.DurationMS == nil || *preserved.DurationMS != measured {
		t.Fatalf("newer state %+v, %v", preserved, err)
	}
	afterEdit, err := s.state(t.Context())
	if err != nil || !reflect.DeepEqual(manualQueue, afterEdit.Queue) {
		t.Fatalf("manual queue changed after import: %+v, %v", afterEdit.Queue, err)
	}
	changedAt := manualQueue.UpdatedAt.Time
	for _, hidden := range [][]int64{{paper, archived.ID}, {}} {
		empty := &queue{EpisodeIDs: hidden, UpdatedAt: timestamp{changedAt.Add(time.Microsecond)}}
		if _, err := s.updateState(t.Context(), stateChange{Queue: empty}, time.Now()); err != nil {
			t.Fatal(err)
		}
		result, err = r.importPinepods(t.Context(), db, "fixture-listener")
		if err != nil || result.queueEntries != 3 {
			t.Fatalf("import into a queue with no visible entries %+v, %v", result, err)
		}
		refilled, err := s.state(t.Context())
		if err != nil || refilled.Queue == nil || !slices.Equal(state.Queue.EpisodeIDs, refilled.Queue.EpisodeIDs) {
			t.Fatalf("import did not refill the queue: %+v, %v", refilled.Queue, err)
		}
		changedAt = refilled.Queue.UpdatedAt.Time
	}
}

func TestImportPinepodsUnavailableFeed(t *testing.T) {
	t.Setenv("EASYPODCAST_ALLOW_PRIVATE_FEEDS", "true")
	for _, tc := range []struct {
		name       string
		unresolved bool
	}{
		{"queued episode has an enclosure", false},
		{"queued episode needs the restored feed", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			source, db := pineTestSource(t)
			s := integrationStore(t)
			var restored atomic.Bool
			first := fixture(t, "first.xml")
			website := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				if req.URL.Path != "/outage" {
					_, _ = w.Write(first)
					return
				}
				if !restored.Load() {
					w.WriteHeader(http.StatusServiceUnavailable)
					return
				}
				_, _ = w.Write([]byte(`<rss><channel><title>Recovered Show</title>
					<item><guid>archive</guid><title>Archived episode</title><enclosure url="/remaster.mp3"/></item>
					<item><guid>recovered</guid><title>Recovered episode</title><enclosure url="/recovered.mp3"/></item>
					</channel></rss>`))
			}))
			defer website.Close()
			testExec(t, source, `INSERT INTO "Podcasts" VALUES
				(21, 7, $1, 2, false, 'Pine Title', 'Pine Author', '<p>Old notes.</p>', '/cover.png', '/studio'),
				(22, 8, $2, 2, false, NULL, NULL, NULL, NULL, NULL)`, website.URL+"/outage", website.URL+"/healthy")
			testExec(t, source, `INSERT INTO "Episodes" VALUES
				(1, 21, 7, 'archive', $1, 'Archived episode', NULL, 0),
				(2, 21, 7, 'recovered', '', 'Recovered episode', NULL, 0),
				(3, 22, 8, 'cloudberry-copper', '', 'Copper Kite', NULL, 0)`, website.URL+"/archive.mp3")
			testExec(t, source, `
				INSERT INTO "UserEpisodeState" VALUES (2,1,true,'2025-10-01 08:24:00');
				INSERT INTO "UserEpisodeHistory" VALUES (2,3,'2025-10-01 08:23:00',30);
				INSERT INTO "EpisodeQueue" VALUES (100,2,1,20,false), (101,2,3,30,false);
			`)
			if tc.unresolved {
				testExec(t, source, `INSERT INTO "EpisodeQueue" VALUES (102,2,2,10,false)`)
			}
			r := newRefresher(s, "EasyPodcast/test", time.Hour)
			summary, err := r.importPinepods(t.Context(), db, "fixture-listener")
			if err != nil || summary.added != 2 || summary.failedFeeds != 1 || summary.matchedCompletions != 1 ||
				summary.matchedPositions != 1 || summary.removedEpisodesAdded != 1 || summary.queueDeferred != tc.unresolved {
				t.Fatalf("first import %+v, %v", summary, err)
			}
			podcasts, err := s.podcasts(t.Context(), false)
			if err != nil || len(podcasts) != 2 {
				t.Fatalf("podcasts %+v, %v", podcasts, err)
			}
			failed := podcasts[0]
			if failed.PlayedCount != 1 || failed.Title != "Pine Title" || failed.Author != "Pine Author" ||
				failed.Description != "Old notes." || failed.ImageURL == nil || *failed.ImageURL != website.URL+"/cover.png" ||
				failed.Link == nil || *failed.Link != website.URL+"/studio" || !failed.Subscribed ||
				failed.LastSuccessAt != nil || failed.LastError == nil || *failed.LastError != "feed returned HTTP 503" {
				t.Fatalf("archived podcast %+v", failed)
			}
			episodes, err := s.episodes(t.Context(), failed.ID)
			if err != nil || len(episodes) != 1 || !episodes[0].RemovedFromFeed || episodes[0].GUID != "archive" {
				t.Fatalf("archived episodes %+v, %v", episodes, err)
			}
			archiveID := episodes[0].ID
			healthy, err := s.episodes(t.Context(), podcasts[1].ID)
			if err != nil || len(healthy) != 2 {
				t.Fatalf("healthy episodes %+v, %v", healthy, err)
			}
			baselineQueue := []int64{archiveID, healthy[0].ID}
			state, err := s.state(t.Context())
			if err != nil || tc.unresolved && state.Queue != nil || !tc.unresolved &&
				(state.Queue == nil || !slices.Equal(state.Queue.EpisodeIDs, baselineQueue)) {
				t.Fatalf("queue after first import %+v, %v", state.Queue, err)
			}

			restored.Store(true)
			summary, err = r.importPinepods(t.Context(), db, "fixture-listener")
			if err != nil || summary.existing != 2 || summary.failedFeeds != 0 || summary.queueDeferred ||
				tc.unresolved && summary.queueEntries != 3 || !tc.unresolved && summary.queueEntries != 0 {
				t.Fatalf("repeat import %+v, %v", summary, err)
			}
			recovered, err := s.podcast(t.Context(), failed.ID)
			if err != nil || recovered.LastError != nil || recovered.LastSuccessAt == nil || recovered.Title != "Recovered Show" ||
				recovered.PlayedCount != 1 {
				t.Fatalf("recovered podcast %+v, %v", recovered, err)
			}
			episodes, err = s.episodes(t.Context(), failed.ID)
			if err != nil || len(episodes) != 2 || episodes[0].ID != archiveID || episodes[0].RemovedFromFeed ||
				!strings.HasSuffix(episodes[0].EnclosureURL, "/remaster.mp3") {
				t.Fatalf("recovered episodes %+v, %v", episodes, err)
			}
			if tc.unresolved {
				baselineQueue = append([]int64{episodes[1].ID}, baselineQueue...)
			}
			state, err = s.state(t.Context())
			if err != nil || state.Queue == nil || !slices.Equal(state.Queue.EpisodeIDs, baselineQueue) {
				t.Fatalf("queue after repeat import %+v, %v, want %v", state.Queue, err, baselineQueue)
			}
		})
	}
}
