package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"reflect"
	"slices"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func TestImportPinepods(t *testing.T) {
	source := isolatedSchema(t)
	s := integrationStore(t)
	feed := fixture(t, "first.xml")
	website := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(feed)
	}))
	defer website.Close()

	testExec(t, source, `
		CREATE TABLE "Users" (UserID int PRIMARY KEY, Username text UNIQUE);
		CREATE TABLE "Podcasts" (PodcastID int PRIMARY KEY, FeedID int, FeedURL text, UserID int, IsYouTubeChannel bool);
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
	testExec(t, source, `INSERT INTO "Podcasts" VALUES
		(21, 7, $1, 2, false), (22, 8, 'broken', 2, true), (11, 7, $1, 1, false), (12, 9, 'foreign', 1, false)`,
		website.URL+"/feeds/cloudberry.xml")
	testExec(t, source, `INSERT INTO "Episodes" VALUES
		(1, 11, 7, 'cloudberry-copper', $1, 'Old copper title', NULL, 3300),
		(2, 21, NULL, 'old-paper-guid', $2, 'Old paper title', NULL, NULL),
		(3, 21, 7, 'missing-from-current-feed', $3, 'Obsidian Bell', '2025-09-20 11:12:13', 811),
		(4, 11, 7, NULL, $4, 'Quiet Archive', NULL, NULL),
		(5, 12, 9, 'other-user-episode', $5, 'Distant Archive', NULL, NULL)`,
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
	db, err := pgx.ConnectConfig(t.Context(), source.Config().ConnConfig)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close(context.Background())
	r := newRefresher(s, "EasyPodcast/test", time.Hour)
	start := time.Now()
	result, err := r.importPinepods(t.Context(), db, "fixture-listener")
	if err != nil {
		t.Fatal(err)
	}
	if want := (pineSummary{
		added: 1, matchedPositions: 1, matchedCompletions: 2, queueEntries: 3,
		removedEpisodesAdded: 2, unmatchedEpisodes: 1,
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
	manualQueue := &queue{EpisodeIDs: []int64{archived.ID}, UpdatedAt: timestamp{state.Queue.UpdatedAt.Add(time.Microsecond)}}
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
	empty := &queue{EpisodeIDs: []int64{}, UpdatedAt: timestamp{manualQueue.UpdatedAt.Add(time.Microsecond)}}
	if _, err := s.updateState(t.Context(), stateChange{Queue: empty}, time.Now()); err != nil {
		t.Fatal(err)
	}
	result, err = r.importPinepods(t.Context(), db, "fixture-listener")
	if err != nil || result.queueEntries != 3 {
		t.Fatalf("import into a stored empty queue %+v, %v", result, err)
	}
	refilled, err := s.state(t.Context())
	if err != nil || refilled.Queue == nil || !slices.Equal(state.Queue.EpisodeIDs, refilled.Queue.EpisodeIDs) {
		t.Fatalf("import did not refill the empty queue: %+v, %v", refilled.Queue, err)
	}
}
