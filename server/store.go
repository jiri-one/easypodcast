package main

import (
	"context"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed migrations/*.sql
var migrations embed.FS

const (
	migrationLock = 47091031
	feedLock      = 47091032
	stateLock     = 47091033
)

type store struct {
	db *pgxpool.Pool
}

func (s store) migrate(ctx context.Context) error {
	files, err := fs.Glob(migrations, "migrations/*.sql")
	if err != nil {
		return err
	}
	return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock($1)", migrationLock); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
			version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now()
		)`); err != nil {
			return err
		}
		for _, file := range files {
			var exists bool
			if err := tx.QueryRow(ctx, "SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version = $1)", file).Scan(&exists); err != nil {
				return err
			}
			if exists {
				continue
			}
			sql, err := migrations.ReadFile(file)
			if err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, string(sql)); err != nil {
				return fmt.Errorf("%s: %w", file, err)
			}
			if _, err := tx.Exec(ctx, "INSERT INTO schema_migrations (version) VALUES ($1)", file); err != nil {
				return err
			}
		}
		return nil
	})
}

type scanner interface {
	Scan(...any) error
}

const podcastSelect = `SELECT p.id, p.feed_url, p.title, p.author, p.description, p.image_url, p.link,
	p.subscribed, counts.total, counts.played, p.episodes_version::text, p.last_success_at, p.last_error
	FROM podcasts p
	CROSS JOIN LATERAL (
		SELECT count(*) AS total, count(*) FILTER (WHERE es.status = 'played') AS played,
			count(es.episode_id) AS states
		FROM episodes e LEFT JOIN episode_state es ON es.episode_id = e.id
		WHERE e.podcast_id = p.id
	) counts`

func scanPodcast(row scanner) (podcast, error) {
	var p podcast
	var success *time.Time
	err := row.Scan(&p.ID, &p.FeedURL, &p.Title, &p.Author, &p.Description, &p.ImageURL, &p.Link,
		&p.Subscribed, &p.EpisodeCount, &p.PlayedCount, &p.EpisodesVersion, &success, &p.LastError)
	p.LastSuccessAt = nullableTimestamp(success)
	return p, err
}

func nullableTimestamp(t *time.Time) *timestamp {
	if t == nil {
		return nil
	}
	return &timestamp{*t}
}

func (s store) podcasts(ctx context.Context, subscribedOnly bool) ([]podcast, error) {
	where := ` WHERE p.subscribed OR counts.states > 0`
	if subscribedOnly {
		where = ` WHERE p.subscribed`
	}
	rows, err := s.db.Query(ctx, podcastSelect+where+" ORDER BY counts.played DESC, p.id")
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (podcast, error) {
		return scanPodcast(row)
	})
}

func (s store) podcast(ctx context.Context, id int64) (podcast, error) {
	return scanPodcast(s.db.QueryRow(ctx, podcastSelect+" WHERE p.id = $1", id))
}

func (s store) unsubscribe(ctx context.Context, id int64) error {
	tag, err := s.db.Exec(ctx, "UPDATE podcasts SET subscribed = false WHERE id = $1", id)
	if err == nil && tag.RowsAffected() == 0 {
		return pgx.ErrNoRows
	}
	return err
}

const episodeColumns = `id, podcast_id, guid, title, published_at, duration_s, enclosure_url,
	enclosure_type, enclosure_length, link, image_url, removed_from_feed`

func scanEpisode(row scanner, e *episode, extra ...any) error {
	var published *time.Time
	args := []any{&e.ID, &e.PodcastID, &e.GUID, &e.Title, &published, &e.DurationSeconds, &e.EnclosureURL,
		&e.EnclosureType, &e.EnclosureLength, &e.Link, &e.ImageURL, &e.RemovedFromFeed}
	err := row.Scan(append(args, extra...)...)
	e.PublishedAt = nullableTimestamp(published)
	return err
}

func (s store) episodes(ctx context.Context, podcastID int64) ([]episode, error) {
	var exists bool
	err := s.db.QueryRow(ctx, "SELECT EXISTS (SELECT 1 FROM podcasts WHERE id = $1)", podcastID).Scan(&exists)
	if err != nil {
		return nil, err
	}
	if !exists {
		return nil, pgx.ErrNoRows
	}
	rows, err := s.db.Query(ctx, "SELECT "+episodeColumns+` FROM episodes WHERE podcast_id = $1
		ORDER BY published_at DESC NULLS LAST, id DESC`, podcastID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (episode, error) {
		var e episode
		err := scanEpisode(row, &e)
		return e, err
	})
}

func (s store) episode(ctx context.Context, id int64) (episodeDetail, error) {
	var result episodeDetail
	err := scanEpisode(s.db.QueryRow(ctx, "SELECT "+episodeColumns+", description FROM episodes WHERE id = $1", id),
		&result.episode, &result.Description)
	return result, err
}

func (s store) episodeState(ctx context.Context, id int64) (*episodeState, error) {
	var position *int64
	var status *string
	var duration *int64
	var updatedAt *time.Time
	err := s.db.QueryRow(ctx, `SELECT es.position_ms, es.status, es.duration_ms, es.updated_at FROM episodes e
		LEFT JOIN episode_state es ON es.episode_id = e.id WHERE e.id = $1`, id).
		Scan(&position, &status, &duration, &updatedAt)
	if err != nil || position == nil {
		return nil, err
	}
	return &episodeState{
		EpisodeID: id, PositionMS: *position, Status: *status, DurationMS: duration, UpdatedAt: timestamp{*updatedAt},
	}, nil
}

func scanEpisodeState(row pgx.CollectableRow) (episodeState, error) {
	var e episodeState
	err := row.Scan(&e.EpisodeID, &e.PositionMS, &e.Status, &e.DurationMS, &e.UpdatedAt.Time)
	return e, err
}

func readQueue(ctx context.Context, tx pgx.Tx) (*queue, error) {
	var q queue
	err := tx.QueryRow(ctx, "SELECT episode_ids, updated_at FROM queue").Scan(&q.EpisodeIDs, &q.UpdatedAt.Time)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return &q, err
}

func (s store) state(ctx context.Context) (stateChange, error) {
	var result stateChange
	err := pgx.BeginTxFunc(ctx, s.db, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, "SELECT episode_id, position_ms, status, duration_ms, updated_at FROM episode_state ORDER BY episode_id")
		if err != nil {
			return err
		}
		result.Episodes, err = pgx.CollectRows(rows, scanEpisodeState)
		if err != nil {
			return err
		}
		result.Queue, err = readQueue(ctx, tx)
		return err
	})
	return result, err
}

var errInvalidState = errors.New("invalid episode or queue state")
var errFutureState = errors.New("updated_at is more than 24 hours ahead of server time")

func (s store) updateState(ctx context.Context, change stateChange, now time.Time) (stateResult, error) {
	latest := make(map[int64]episodeState, len(change.Episodes))
	ids := make([]int64, 0, len(change.Episodes))
	limit := now.Add(24 * time.Hour)
	for _, e := range change.Episodes {
		if e.UpdatedAt.After(limit) {
			return stateResult{}, errFutureState
		}
		if e.UpdatedAt.IsZero() || e.PositionMS < 0 || (e.Status != "" && e.Status != "played" && e.Status != "dismissed") {
			return stateResult{}, errInvalidState
		}
		current, exists := latest[e.EpisodeID]
		if !exists {
			ids = append(ids, e.EpisodeID)
		}
		if !exists || e.UpdatedAt.After(current.UpdatedAt.Time) {
			latest[e.EpisodeID] = e
		}
	}
	if change.Queue != nil {
		if change.Queue.UpdatedAt.After(limit) {
			return stateResult{}, errFutureState
		}
		if change.Queue.UpdatedAt.IsZero() || change.Queue.EpisodeIDs == nil {
			return stateResult{}, errInvalidState
		}
	}
	result := stateResult{stateChange: stateChange{Episodes: []episodeState{}}, Unknown: []int64{}}
	err := pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		err := applyStates(ctx, tx, ids, latest, change.Queue, change.queueOnlyIfEmpty, &result)
		if err != nil {
			return err
		}
		result.Queue, err = readQueue(ctx, tx)
		return err
	})
	return result, err
}

func applyStates(ctx context.Context, tx pgx.Tx, ids []int64, latest map[int64]episodeState, q *queue, queueOnlyIfEmpty bool, result *stateResult) error {
	if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock($1)", stateLock); err != nil {
		return err
	}
	lookupIDs := ids
	if q != nil {
		lookupIDs = append(append([]int64{}, ids...), q.EpisodeIDs...)
	}
	rows, err := tx.Query(ctx, "SELECT id FROM episodes WHERE id = ANY($1)", lookupIDs)
	if err != nil {
		return err
	}
	known, err := pgx.CollectRows(rows, pgx.RowTo[int64])
	if err != nil {
		return err
	}
	exists := make(map[int64]bool, len(known))
	for _, id := range known {
		exists[id] = true
	}
	unknown := make(map[int64]bool)
	for _, id := range lookupIDs {
		if !exists[id] && !unknown[id] {
			unknown[id] = true
			result.Unknown = append(result.Unknown, id)
		}
	}

	batch := &pgx.Batch{}
	for _, id := range ids {
		if !exists[id] {
			continue
		}
		e := latest[id]
		batch.Queue(`INSERT INTO episode_state (episode_id, position_ms, status, duration_ms, updated_at) VALUES ($1,$2,$3,$4,$5)
			ON CONFLICT (episode_id) DO UPDATE SET position_ms = EXCLUDED.position_ms,
			status = EXCLUDED.status, duration_ms = EXCLUDED.duration_ms, updated_at = EXCLUDED.updated_at
			WHERE EXCLUDED.updated_at > episode_state.updated_at`, id, e.PositionMS, e.Status, e.DurationMS, e.UpdatedAt.Time)
	}
	if q != nil {
		filtered := make([]int64, 0, len(q.EpisodeIDs))
		for _, id := range q.EpisodeIDs {
			if exists[id] {
				filtered = append(filtered, id)
			}
		}
		batch.Queue(`INSERT INTO queue (episode_ids, updated_at) VALUES ($1,$2)
			ON CONFLICT (singleton) DO UPDATE SET episode_ids = EXCLUDED.episode_ids, updated_at = EXCLUDED.updated_at
			WHERE EXCLUDED.updated_at > queue.updated_at AND (NOT $3 OR cardinality(queue.episode_ids) = 0)`,
			filtered, q.UpdatedAt.Time, queueOnlyIfEmpty).Exec(func(tag pgconn.CommandTag) error {
			if tag.RowsAffected() != 0 {
				result.queueEntriesWritten = len(filtered)
			}
			return nil
		})
	}
	if err := tx.SendBatch(ctx, batch).Close(); err != nil {
		return err
	}
	rows, err = tx.Query(ctx, `SELECT es.episode_id, es.position_ms, es.status, es.duration_ms, es.updated_at
		FROM unnest($1::bigint[]) WITH ORDINALITY AS input(id, position)
		JOIN episode_state es ON es.episode_id = input.id ORDER BY input.position`, ids)
	if err != nil {
		return err
	}
	result.Episodes, err = pgx.CollectRows(rows, scanEpisodeState)
	return err
}
