package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

type pineSubscription struct {
	PodcastID int64
	FeedID    *int64
	URL       string
}

type pineEpisode struct {
	ID            int64
	PodcastID     *int64
	FeedID        *int64
	GUID          string
	EnclosureURL  string
	ListenSeconds *int32
	ListenDate    *time.Time
	Completed     bool
	CompletedAt   *time.Time
}

type pineSnapshot struct {
	subscriptions []pineSubscription
	episodes      []pineEpisode
	queue         []int64
}

type pineSummary struct {
	added               int
	existing            int
	failedFeeds         int
	matchedPositions    int
	matchedCompletions  int
	queueEntries        int
	unmatchedEpisodes   int
	missingCompletionAt int
	skippedStates       int
}

func importPinepodsCommand(ctx context.Context, s store, args []string) error {
	flags := flag.NewFlagSet("import-pinepods", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	dsn := flags.String("pinepods-dsn", "", "")
	username := flags.String("pinepods-user", "", "")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 || *dsn == "" || *username == "" {
		return errors.New("usage: easypodcast import-pinepods --pinepods-dsn <dsn> --pinepods-user <name>")
	}
	r, err := configureRefresher(s)
	if err != nil {
		return err
	}
	source, err := pgx.Connect(ctx, *dsn)
	if err != nil {
		return errors.New("could not connect to PinePods")
	}
	defer source.Close(context.Background())
	summary, err := r.importPinepods(ctx, source, *username)
	if err != nil {
		return err
	}
	fmt.Printf("Subscriptions added %d, existing %d, feed failures %d\n", summary.added, summary.existing, summary.failedFeeds)
	fmt.Printf("Matched positions %d, completions %d, queue entries %d, unmatched episodes %d\n",
		summary.matchedPositions, summary.matchedCompletions, summary.queueEntries, summary.unmatchedEpisodes)
	fmt.Printf("Completions without a completion time %d, states skipped for missing or future timestamps %d\n",
		summary.missingCompletionAt, summary.skippedStates)
	if summary.failedFeeds > 0 {
		return errors.New("some PinePods feeds could not be refreshed")
	}
	return nil
}

var errPineUserMissing = errors.New("PinePods user not found")

func readPinepods(ctx context.Context, db *pgx.Conn, username string) (pineSnapshot, error) {
	var data pineSnapshot
	err := pgx.BeginTxFunc(ctx, db, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		var user int64
		err := tx.QueryRow(ctx, `SELECT userid FROM "Users" WHERE username = $1`, username).Scan(&user)
		if errors.Is(err, pgx.ErrNoRows) {
			return errPineUserMissing
		}
		if err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT p.podcastid, p.feedid, COALESCE(p.feedurl, '')
			FROM "Podcasts" p WHERE p.userid = $1 AND NOT COALESCE(p.isyoutubechannel, false)
			ORDER BY p.podcastid`, user)
		if err != nil {
			return err
		}
		data.subscriptions, err = pgx.CollectRows(rows, pgx.RowToStructByPos[pineSubscription])
		if err != nil {
			return err
		}

		rows, err = tx.Query(ctx, `SELECT episodeid FROM "EpisodeQueue" WHERE userid = $1
			AND NOT COALESCE(is_youtube, false) AND episodeid IS NOT NULL ORDER BY queueposition, queueid`, user)
		if err != nil {
			return err
		}
		data.queue, err = pgx.CollectRows(rows, pgx.RowTo[int64])
		if err != nil {
			return err
		}

		rows, err = tx.Query(ctx, `WITH touched AS (
				SELECT episodeid FROM "UserEpisodeHistory" WHERE userid = $1
				UNION SELECT episodeid FROM "UserEpisodeState" WHERE userid = $1 AND completed
				UNION SELECT unnest($2::int[])
			)
			SELECT t.episodeid, e.podcastid, e.feedid, COALESCE(e.episodeguid, ''), COALESCE(e.episodeurl, ''),
				h.listenduration, h.listendate AT TIME ZONE 'UTC', COALESCE(s.completed, false),
				s.completedat AT TIME ZONE 'UTC'
			FROM touched t
			LEFT JOIN "Episodes" e ON e.episodeid = t.episodeid
			LEFT JOIN "UserEpisodeHistory" h ON h.episodeid = t.episodeid AND h.userid = $1
			LEFT JOIN "UserEpisodeState" s ON s.episodeid = t.episodeid AND s.userid = $1
			WHERE t.episodeid IS NOT NULL ORDER BY t.episodeid`, user, data.queue)
		if err != nil {
			return err
		}
		data.episodes, err = pgx.CollectRows(rows, pgx.RowToStructByPos[pineEpisode])
		return err
	})
	return data, err
}

type pineMatcher struct {
	byGUID map[string]int64
	byURL  map[string]int64
}

func (r *refresher) importPinepods(ctx context.Context, db *pgx.Conn, username string) (pineSummary, error) {
	data, err := readPinepods(ctx, db, username)
	if errors.Is(err, errPineUserMissing) {
		return pineSummary{}, err
	}
	if err != nil {
		return pineSummary{}, databaseError("could not read PinePods 0.9.2 data", err)
	}
	var summary pineSummary
	byFeed := make(map[int64]*pineMatcher)
	byPodcast := make(map[int64]*pineMatcher)
	matchers := make(map[int64]*pineMatcher)
	for _, sub := range data.subscriptions {
		p, added, err := r.subscribe(ctx, sub.URL)
		if err != nil {
			var issue feedError
			if !errors.As(err, &issue) {
				return summary, databaseError("could not import PinePods subscription", err)
			}
			summary.failedFeeds++
			continue
		}
		if added {
			summary.added++
		} else {
			summary.existing++
		}
		matcher := matchers[p.ID]
		if matcher == nil {
			if !added {
				target, err := r.store.feedTarget(ctx, p.ID)
				if err != nil {
					return summary, databaseError("could not look up imported subscription", err)
				}
				if err := r.refresh(ctx, target); err != nil {
					summary.failedFeeds++
				}
			}
			matcher, err = r.store.pineMatcher(ctx, p.ID)
			if err != nil {
				return summary, databaseError("could not load episodes for matching", err)
			}
			matchers[p.ID] = matcher
		}
		if sub.FeedID != nil {
			byFeed[*sub.FeedID] = matcher
		}
		byPodcast[sub.PodcastID] = matcher
	}
	now := time.Now()
	change := stateChange{Queue: &queue{EpisodeIDs: []int64{}, UpdatedAt: timestamp{now}}}
	destinations := make(map[int64]int64)
	for _, source := range data.episodes {
		var matcher *pineMatcher
		if source.FeedID != nil {
			matcher = byFeed[*source.FeedID]
		} else if source.PodcastID != nil {
			matcher = byPodcast[*source.PodcastID]
		}
		var id int64
		if matcher != nil {
			id = matcher.byGUID[strings.TrimSpace(source.GUID)]
			if id == 0 {
				id = matcher.byURL[source.EnclosureURL]
			}
		}
		if id == 0 {
			summary.unmatchedEpisodes++
			continue
		}
		destinations[source.ID] = id
		if e, ok := source.toState(id, now, &summary); ok {
			change.Episodes = append(change.Episodes, e)
		}
	}
	for _, id := range data.queue {
		if episodeID := destinations[id]; episodeID != 0 {
			change.Queue.EpisodeIDs = append(change.Queue.EpisodeIDs, episodeID)
		}
	}
	summary.queueEntries = len(change.Queue.EpisodeIDs)
	if _, err := r.store.updateState(ctx, change, now); err != nil {
		return summary, databaseError("could not apply PinePods listening state", err)
	}
	return summary, nil
}

func (e pineEpisode) toState(id int64, now time.Time, summary *pineSummary) (episodeState, bool) {
	state := episodeState{EpisodeID: id}
	updated := e.ListenDate
	if e.Completed {
		state.Status = "played"
		updated = e.CompletedAt
		if updated == nil {
			summary.missingCompletionAt++
			updated = e.ListenDate
			if updated == nil {
				oldest := time.UnixMilli(1)
				updated = &oldest
			}
		}
	} else if e.ListenSeconds != nil {
		state.PositionMS = max(0, int64(*e.ListenSeconds)) * 1000
	} else {
		return episodeState{}, false
	}
	if updated == nil || updated.IsZero() || updated.After(now.Add(24*time.Hour)) {
		summary.skippedStates++
		return episodeState{}, false
	}
	state.UpdatedAt = timestamp{*updated}
	if e.Completed {
		summary.matchedCompletions++
	} else {
		summary.matchedPositions++
	}
	return state, true
}

func (s store) pineMatcher(ctx context.Context, podcastID int64) (*pineMatcher, error) {
	rows, err := s.db.Query(ctx, `SELECT id, guid, enclosure_url FROM episodes WHERE podcast_id = $1
		ORDER BY removed_from_feed, id`, podcastID)
	if err != nil {
		return nil, err
	}
	identities, err := pgx.CollectRows(rows, pgx.RowToStructByPos[episodeIdentity])
	if err != nil {
		return nil, err
	}
	matcher := &pineMatcher{byGUID: make(map[string]int64), byURL: make(map[string]int64)}
	for _, e := range identities {
		if e.GUID != "" {
			matcher.byGUID[e.GUID] = e.ID
		}
		if matcher.byURL[e.EnclosureURL] == 0 {
			matcher.byURL[e.EnclosureURL] = e.ID
		}
	}
	return matcher, nil
}
