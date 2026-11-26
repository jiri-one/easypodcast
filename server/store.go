package main

import (
	"context"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed migrations/*.sql
var migrations embed.FS

const (
	migrationLock        = 47091031
	feedLock             = 47091032
	feedRefreshMigration = "migrations/006_feed_refresh.sql"
)

var errUnknownMigration = errors.New("database has a migration this binary does not know")
var errIncompleteSchema = errors.New("database migrations are incomplete")

type store struct {
	db         *pgxpool.Pool
	feedWrites chan struct{}
}

func newStore(db *pgxpool.Pool) store {
	return store{db: db, feedWrites: make(chan struct{}, 1)}
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
		applied, err := appliedMigrations(ctx, tx, files)
		if err != nil {
			return err
		}
		for _, file := range files {
			if slices.Contains(applied, file) {
				continue
			}
			sql, err := migrations.ReadFile(file)
			if err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, string(sql)); err != nil {
				return fmt.Errorf("%s: %w", file, err)
			}
			if file == feedRefreshMigration {
				if err := migrateFeedAliases(ctx, tx); err != nil {
					return err
				}
			}
			if _, err := tx.Exec(ctx, "INSERT INTO schema_migrations (version) VALUES ($1)", file); err != nil {
				return err
			}
		}
		return nil
	})
}

func appliedMigrations(ctx context.Context, db interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
}, known []string) ([]string, error) {
	rows, err := db.Query(ctx, "SELECT version FROM schema_migrations")
	if err != nil {
		return nil, err
	}
	applied, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, err
	}
	for _, file := range applied {
		if !slices.Contains(known, file) {
			return nil, errUnknownMigration
		}
	}
	return applied, nil
}

func (s store) checkSchema(ctx context.Context) error {
	files, err := fs.Glob(migrations, "migrations/*.sql")
	if err != nil {
		return err
	}
	applied, err := appliedMigrations(ctx, s.db, files)
	if err != nil {
		return err
	}
	if len(applied) != len(files) {
		return errIncompleteSchema
	}
	return nil
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
	where := ` WHERE p.subscribed OR counts.states > 0 OR p.id IN (
		SELECT e.podcast_id FROM queue q JOIN episodes e ON e.id = ANY(q.episode_ids))`
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
	rows, err := s.db.Query(ctx, "SELECT "+episodeColumns+` FROM episodes
		LEFT JOIN (
			SELECT f.episode_id, f.position FROM podcasts p CROSS JOIN LATERAL
				unnest(p.feed_episode_order) WITH ORDINALITY AS f(episode_id, position) WHERE p.id = $1
		) AS feed ON feed.episode_id = episodes.id
		WHERE podcast_id = $1 ORDER BY COALESCE(published_at, estimated_publication) DESC NULLS LAST,
			COALESCE(feed.position - 1, feed_order) NULLS LAST, id DESC`, podcastID)
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

const episodeStateColumns = "episode_id, position_ms, status, duration_ms, updated_at"

func (s store) episodeState(ctx context.Context, id int64) (*episodeState, error) {
	var episodeID, position, duration *int64
	var status *string
	var updatedAt *time.Time
	err := s.db.QueryRow(ctx, "SELECT "+episodeStateColumns+` FROM episodes e
		LEFT JOIN episode_state es ON es.episode_id = e.id WHERE e.id = $1`, id).
		Scan(&episodeID, &position, &status, &duration, &updatedAt)
	if err != nil || episodeID == nil {
		return nil, err
	}
	return &episodeState{
		EpisodeID: *episodeID, PositionMS: *position, Status: *status, DurationMS: duration, UpdatedAt: timestamp{*updatedAt},
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

const stateRevisionSQL = "SELECT server_id::text, state_version FROM server_metadata"

func scanStateRevision(row scanner) (stateRevision, error) {
	var revision stateRevision
	err := row.Scan(&revision.ServerID, &revision.version)
	if errors.Is(err, pgx.ErrNoRows) {
		err = errors.New("database is missing the server identity")
	}
	return revision, err
}

func (s store) currentStateRevision(ctx context.Context) (stateRevision, error) {
	return scanStateRevision(s.db.QueryRow(ctx, stateRevisionSQL))
}

func (s store) newServerID(ctx context.Context) error {
	tag, err := s.db.Exec(ctx, "UPDATE server_metadata SET server_id = DEFAULT")
	if err == nil && tag.RowsAffected() != 1 {
		return errors.New("database is missing the server identity")
	}
	return err
}

func (s store) state(ctx context.Context) (stateSnapshot, error) {
	var result stateSnapshot
	err := pgx.BeginTxFunc(ctx, s.db, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		revision, err := scanStateRevision(tx.QueryRow(ctx, stateRevisionSQL))
		if err != nil {
			return err
		}
		result.stateRevision = revision
		rows, err := tx.Query(ctx, "SELECT "+episodeStateColumns+" FROM episode_state ORDER BY episode_id")
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
var errServerIDChanged = errors.New("server identity changed")

func (s store) updateState(ctx context.Context, change stateChange, now time.Time) (stateResult, error) {
	latest := make(map[int64]episodeState, len(change.Episodes))
	ids := make([]int64, 0, len(change.Episodes))
	result := stateResult{Unknown: []int64{}, Future: []any{}}
	limit := now.Add(24 * time.Hour)
	for _, e := range change.Episodes {
		if e.UpdatedAt.IsZero() || e.PositionMS < 0 || (e.Status != "" && e.Status != "played" && e.Status != "dismissed") {
			return stateResult{}, errInvalidState
		}
		if e.UpdatedAt.After(limit) {
			result.Future = append(result.Future, e.EpisodeID)
			continue
		}
		current, exists := latest[e.EpisodeID]
		if !exists {
			ids = append(ids, e.EpisodeID)
		}
		if !exists || e.UpdatedAt.After(current.UpdatedAt.Time) {
			latest[e.EpisodeID] = e
		}
	}
	if q := change.Queue; q != nil {
		if q.UpdatedAt.IsZero() || q.EpisodeIDs == nil {
			return stateResult{}, errInvalidState
		}
		if q.UpdatedAt.After(limit) {
			result.Future = append(result.Future, "queue")
			change.Queue = nil
		}
	}
	err := pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		revision, err := scanStateRevision(tx.QueryRow(ctx, stateRevisionSQL+" FOR UPDATE"))
		if err != nil {
			return err
		}
		result.ServerID = revision.ServerID
		if id := change.expectedServerID; id != nil && *id != result.ServerID {
			return errServerIDChanged
		}
		if err := applyStates(ctx, tx, ids, latest, change.Queue, change.queueOnlyIfEmpty, &result); err != nil {
			return err
		}
		result.Queue, err = readQueue(ctx, tx)
		return err
	})
	return result, err
}

func applyStates(ctx context.Context, tx pgx.Tx, ids []int64, latest map[int64]episodeState, q *queue, queueOnlyIfEmpty bool, result *stateResult) error {
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
	changed := false
	for _, id := range ids {
		if !exists[id] {
			continue
		}
		e := latest[id]
		batch.Queue(`INSERT INTO episode_state (`+episodeStateColumns+`) VALUES ($1,$2,$3,$4,$5)
			ON CONFLICT (episode_id) DO UPDATE SET position_ms = EXCLUDED.position_ms,
			status = EXCLUDED.status, duration_ms = EXCLUDED.duration_ms, updated_at = EXCLUDED.updated_at
			WHERE EXCLUDED.updated_at > episode_state.updated_at`, id, e.PositionMS, e.Status, e.DurationMS, e.UpdatedAt.Time).
			Exec(func(tag pgconn.CommandTag) error {
				changed = changed || tag.RowsAffected() != 0
				return nil
			})
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
			WHERE EXCLUDED.updated_at > queue.updated_at AND (NOT $3 OR NOT EXISTS (
				SELECT 1 FROM unnest(queue.episode_ids) AS shown(id)
				LEFT JOIN episode_state es ON es.episode_id = shown.id WHERE COALESCE(es.status, '') = ''))`,
			filtered, q.UpdatedAt.Time, queueOnlyIfEmpty).Exec(func(tag pgconn.CommandTag) error {
			if tag.RowsAffected() != 0 {
				changed = true
				result.queueEntriesWritten = len(filtered)
			}
			return nil
		})
	}
	if err := tx.SendBatch(ctx, batch).Close(); err != nil {
		return err
	}
	if changed {
		if _, err := tx.Exec(ctx, "UPDATE server_metadata SET state_version = state_version + 1"); err != nil {
			return err
		}
	}
	rows, err = tx.Query(ctx, "SELECT "+episodeStateColumns+`
		FROM unnest($1::bigint[]) WITH ORDINALITY AS input(id, position)
		JOIN episode_state es ON es.episode_id = input.id ORDER BY input.position`, ids)
	if err != nil {
		return err
	}
	result.Episodes, err = pgx.CollectRows(rows, scanEpisodeState)
	return err
}
