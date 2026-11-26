package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/url"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

type pineSubscription struct {
	PodcastID int64
	FeedID    *int64
	URL       string
	Title     string
	Author    string
	Details   string
	Image     string
	Website   string
}

type pineEpisode struct {
	ID            int64
	PodcastID     *int64
	FeedID        *int64
	GUID          string
	EnclosureURL  string
	Title         string
	PublishedAt   *time.Time
	Duration      *int64
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
	added                 int
	existing              int
	failedFeeds           int
	matchedPositions      int
	matchedCompletions    int
	queueEntries          int
	unmatchedQueueEntries int
	queueDeferred         bool
	removedEpisodesAdded  int
	unmatchedEpisodes     int
	missingCompletionAt   int
	skippedStates         int
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
	fmt.Printf("Matched positions %d, completions %d, queue entries imported %d, removed episodes added %d, unmatched episodes %d\n",
		summary.matchedPositions, summary.matchedCompletions, summary.queueEntries, summary.removedEpisodesAdded, summary.unmatchedEpisodes)
	if summary.queueDeferred {
		fmt.Println("Queue import deferred until its feeds can be fetched")
	} else if summary.unmatchedQueueEntries > 0 {
		fmt.Printf("Unmatched PinePods queue entries %d\n", summary.unmatchedQueueEntries)
	}
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
		rows, err := tx.Query(ctx, `SELECT p.podcastid, p.feedid, COALESCE(p.feedurl, ''), COALESCE(p.podcastname, ''),
			COALESCE(p.author, ''), COALESCE(p.description, ''), COALESCE(p.artworkurl, ''), COALESCE(p.websiteurl, '')
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

		rows, err = tx.Query(ctx, `WITH candidates AS (
				SELECT e.episodeid FROM "Episodes" e JOIN "Podcasts" p
					ON (p.feedid = e.feedid OR p.podcastid = e.podcastid)
				WHERE p.userid = $1 AND NOT COALESCE(p.isyoutubechannel, false)
				UNION SELECT episodeid FROM "UserEpisodeHistory" WHERE userid = $1
				UNION SELECT episodeid FROM "UserEpisodeState" WHERE userid = $1 AND completed
				UNION SELECT unnest($2::int[])
			)
			SELECT t.episodeid, e.podcastid, e.feedid, COALESCE(e.episodeguid, ''), COALESCE(e.episodeurl, ''),
				COALESCE(e.episodetitle, ''), e.episodepubdate AT TIME ZONE 'UTC', NULLIF(e.episodeduration, 0),
				h.listenduration, h.listendate AT TIME ZONE 'UTC', COALESCE(s.completed, false),
				s.completedat AT TIME ZONE 'UTC'
			FROM candidates t
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

func (r *refresher) importPinepods(ctx context.Context, db *pgx.Conn, username string) (pineSummary, error) {
	data, err := readPinepods(ctx, db, username)
	if errors.Is(err, errPineUserMissing) {
		return pineSummary{}, err
	}
	if err != nil {
		return pineSummary{}, databaseError("could not read PinePods 0.9.2 data", err)
	}
	var summary pineSummary
	byFeed := make(map[int64]int64)
	byPodcast := make(map[int64]int64)
	seen := make(map[int64]bool)
	failedPodcasts := make(map[int64]bool)
	for _, sub := range data.subscriptions {
		p, added, err := r.subscribe(ctx, sub.URL)
		failed := false
		if err != nil {
			var issue feedError
			if !errors.As(err, &issue) {
				return summary, databaseError("could not import PinePods subscription", err)
			}
			summary.failedFeeds++
			address, parseErr := feedURL(sub.URL)
			if parseErr != nil {
				continue
			}
			p.ID, added, err = r.store.archivePineFeed(ctx, address, sub, issue, time.Now().Add(r.delay(1)))
			if err != nil {
				return summary, databaseError("could not archive PinePods subscription", err)
			}
			failed = true
		}
		if added {
			summary.added++
		} else {
			summary.existing++
		}
		if !added && !failed && !seen[p.ID] {
			target, err := r.store.feedTarget(ctx, p.ID)
			if err != nil {
				return summary, databaseError("could not look up imported subscription", err)
			}
			if err := r.refresh(ctx, target); err != nil {
				summary.failedFeeds++
				failed = true
			}
		}
		if failed {
			failedPodcasts[p.ID] = true
		}
		seen[p.ID] = true
		if sub.FeedID != nil {
			byFeed[*sub.FeedID] = p.ID
		}
		byPodcast[sub.PodcastID] = p.ID
	}
	episodesByPodcast := make(map[int64][]pineEpisode)
	for _, source := range data.episodes {
		var podcastID int64
		if source.FeedID != nil {
			podcastID = byFeed[*source.FeedID]
		}
		if podcastID == 0 && source.PodcastID != nil {
			podcastID = byPodcast[*source.PodcastID]
		}
		if podcastID != 0 {
			episodesByPodcast[podcastID] = append(episodesByPodcast[podcastID], source)
		}
	}
	destinations, removedAdded, err := r.store.matchPineEpisodes(ctx, episodesByPodcast)
	if err != nil {
		return summary, databaseError("could not reconcile PinePods episodes", err)
	}
	summary.removedEpisodesAdded = removedAdded
	now := time.Now()
	change := stateChange{queueOnlyIfEmpty: true}
	for _, source := range data.episodes {
		id := destinations[source.ID]
		if id == 0 {
			summary.unmatchedEpisodes++
			continue
		}
		if e, ok := source.toState(id, now, &summary); ok {
			change.Episodes = append(change.Episodes, e)
		}
	}
	unresolved := make(map[int64]bool)
	for podcastID := range failedPodcasts {
		for _, source := range episodesByPodcast[podcastID] {
			if destinations[source.ID] == 0 && strings.TrimSpace(source.GUID) != "" {
				unresolved[source.ID] = true
			}
		}
	}
	var queued []int64
	for _, id := range data.queue {
		if episodeID := destinations[id]; episodeID != 0 {
			queued = append(queued, episodeID)
		} else if unresolved[id] {
			summary.queueDeferred = true
		} else {
			summary.unmatchedQueueEntries++
		}
	}
	if len(queued) > 0 && !summary.queueDeferred {
		change.Queue = &queue{EpisodeIDs: queued, UpdatedAt: timestamp{now}}
	}
	result, err := r.store.updateState(ctx, change, now)
	if err != nil {
		return summary, databaseError("could not apply PinePods listening state", err)
	}
	summary.queueEntries = result.queueEntriesWritten
	return summary, nil
}

func (s store) archivePineFeed(ctx context.Context, u *url.URL, source pineSubscription, issue feedError, next time.Time) (int64, bool, error) {
	address := u.String()
	title := strings.TrimSpace(source.Title)
	if title == "" {
		title = address
	}
	description := plainText(source.Details, u)
	image, website := resolveLink(u, source.Image), resolveLink(u, source.Website)
	var id int64
	var added bool
	err := s.withFeedLock(ctx, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, resubscribeSQL, address).Scan(&id)
		if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		err = tx.QueryRow(ctx, `INSERT INTO podcasts (feed_url, title, author, description, image_url, link,
			last_error, failures, next_refresh_at) VALUES ($1,$2,$3,$4,$5,$6,$7,1,$8) RETURNING id`,
			address, title, source.Author, description, image, website, string(issue), next).Scan(&id)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, "INSERT INTO feed_aliases (url, podcast_id) VALUES ($1,$2)", address, id)
		added = err == nil
		return err
	})
	return id, added, err
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

func (s store) matchPineEpisodes(ctx context.Context, groups map[int64][]pineEpisode) (map[int64]int64, int, error) {
	matched := make(map[int64]int64)
	added := 0
	err := s.withFeedLock(ctx, func(tx pgx.Tx) error {
		for podcastID, episodes := range groups {
			count, err := matchPinePodcast(ctx, tx, podcastID, episodes, matched)
			if err != nil {
				return err
			}
			added += count
		}
		return nil
	})
	return matched, added, err
}

func matchPinePodcast(ctx context.Context, tx pgx.Tx, podcastID int64, sources []pineEpisode, matched map[int64]int64) (int, error) {
	identities, err := episodeIdentities(ctx, tx, podcastID)
	if err != nil {
		return 0, err
	}
	counts := make(map[string]int)
	for _, source := range sources {
		counts[strings.TrimSpace(source.GUID)]++
	}
	ambiguous, err := rememberAmbiguousGUIDs(ctx, tx, podcastID, counts)
	if err != nil {
		return 0, err
	}
	byGUID := make(map[string]int64, len(identities))
	byURL := make(map[string]int64, len(identities))
	for _, e := range identities {
		if e.GUID != "" {
			byGUID[e.GUID] = e.ID
		}
		if e.EnclosureURL != "" && byURL[e.EnclosureURL] == 0 {
			byURL[e.EnclosureURL] = e.ID
		}
	}
	added := 0
	for _, source := range sources {
		guid := strings.TrimSpace(source.GUID)
		if ambiguous[guid] {
			guid = ""
		}
		enclosure := strings.TrimSpace(source.EnclosureURL)
		id := byGUID[guid]
		if id == 0 {
			id = byURL[enclosure]
		}
		if id != 0 {
			matched[source.ID] = id
			continue
		}
		if _, err := feedURL(enclosure); err != nil {
			continue
		}
		err := tx.QueryRow(ctx, `INSERT INTO episodes
			(podcast_id, guid, enclosure_url, title, published_at, duration_s, description, removed_from_feed)
			VALUES ($1,$2,$3,$4,$5,$6,'',true) RETURNING id`,
			podcastID, guid, enclosure, source.Title, source.PublishedAt, source.Duration).Scan(&id)
		if err != nil {
			return 0, err
		}
		if guid != "" {
			byGUID[guid] = id
		}
		byURL[enclosure] = id
		matched[source.ID] = id
		added++
	}
	if added > 0 {
		_, err = tx.Exec(ctx, "UPDATE podcasts SET episodes_version = episodes_version + 1 WHERE id = $1", podcastID)
	}
	return added, err
}
