package main

import (
	"context"
	"net/http"
	"net/http/httptest"
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
		CREATE TABLE "Episodes" (EpisodeID int PRIMARY KEY, PodcastID int, FeedID int, EpisodeGUID text, EpisodeURL text);
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
		(21, 7, $1, 2, false), (22, 8, 'broken', 2, true), (11, 7, $1, 1, false)`, website.URL+"/feeds/cloudberry.xml")
	testExec(t, source, `INSERT INTO "Episodes" VALUES
		(1, 11, 7, 'cloudberry-copper', $1),
		(2, 21, NULL, 'old-paper-guid', $2),
		(3, 21, 7, 'missing-from-current-feed', $3)`,
		website.URL+"/outdated", website.URL+"/audio/paper.mp3", website.URL+"/absent")
	testExec(t, source, `
		INSERT INTO "UserEpisodeHistory" VALUES
			(2,1,'2025-10-01 08:10:00.123',132),
			(2,2,'2025-10-01 08:22:00',20),
			(2,3,'2025-10-01 08:23:00',30),
			(1,1,'2025-10-02 09:00:00',999);
		INSERT INTO "UserEpisodeState" VALUES
			(2,2,true,'2025-10-01 08:20:00.456'),
			(1,1,true,'2025-10-02 09:00:00');
		INSERT INTO "EpisodeQueue" VALUES
			(100,2,1,30,false), (101,2,2,10,false), (102,2,3,20,false), (103,2,1,1,true);
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
	if want := (pineSummary{added: 1, matchedPositions: 1, matchedCompletions: 1, queueEntries: 2, unmatchedEpisodes: 1}); result != want {
		t.Fatalf("summary %+v, want %+v", result, want)
	}
	podcasts, err := s.podcasts(t.Context(), false)
	if err != nil || len(podcasts) != 1 || podcasts[0].PlayedCount != 1 {
		t.Fatalf("podcasts %+v, %v", podcasts, err)
	}
	episodes, err := s.episodes(t.Context(), podcasts[0].ID)
	if err != nil || len(episodes) != 2 {
		t.Fatalf("episodes %+v, %v", episodes, err)
	}
	copper, paper := episodes[0].ID, episodes[1].ID
	listenAt := time.Date(2025, 10, 1, 8, 10, 0, 123_000_000, time.UTC)
	doneAt := time.Date(2025, 10, 1, 8, 20, 0, 456_000_000, time.UTC)
	position, err := s.episodeState(t.Context(), copper)
	if err != nil || position == nil || position.PositionMS != 132000 || position.Status != "" || !position.UpdatedAt.Equal(listenAt) {
		t.Fatalf("position %+v, %v", position, err)
	}
	completed, err := s.episodeState(t.Context(), paper)
	if err != nil || completed == nil || completed.PositionMS != 0 || completed.Status != "played" || !completed.UpdatedAt.Equal(doneAt) {
		t.Fatalf("completion %+v, %v", completed, err)
	}
	state, err := s.state(t.Context())
	if err != nil || state.Queue == nil || !slices.Equal(state.Queue.EpisodeIDs, []int64{paper, copper}) ||
		state.Queue.UpdatedAt.Before(start.Add(-time.Microsecond)) || state.Queue.UpdatedAt.After(time.Now()) {
		t.Fatalf("queue %+v, %v", state.Queue, err)
	}

	newer := episodeState{copper, 1800, "dismissed", timestamp{listenAt.Add(time.Hour)}}
	if _, err := s.updateState(t.Context(), stateChange{Episodes: []episodeState{newer}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	result, err = r.importPinepods(t.Context(), db, "fixture-listener")
	if err != nil || result.added != 0 || result.existing != 1 {
		t.Fatalf("second import %+v, %v", result, err)
	}
	preserved, err := s.episodeState(t.Context(), copper)
	if err != nil || preserved == nil || preserved.Status != "dismissed" || preserved.PositionMS != 1800 {
		t.Fatalf("newer state %+v, %v", preserved, err)
	}
}
