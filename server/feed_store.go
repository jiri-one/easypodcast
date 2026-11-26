package main

import (
	"context"
	"crypto/sha256"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

const maxStoredFeedEpisodes = 50_000
const errStoredEpisodeLimit = feedError("podcast has reached the stored episode limit")

func (s store) withFeedWriter(ctx context.Context, fn func() error) error {
	select {
	case s.feedWrites <- struct{}{}:
		defer func() { <-s.feedWrites }()
	case <-ctx.Done():
		return ctx.Err()
	}
	return fn()
}

func (s store) withFeedLock(ctx context.Context, fn func(pgx.Tx) error) error {
	return s.withFeedWriter(ctx, func() error {
		return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock($1)", feedLock); err != nil {
				return err
			}
			return fn(tx)
		})
	})
}

const resubscribeSQL = `UPDATE podcasts p SET subscribed = true,
		next_refresh_at = CASE WHEN p.subscribed THEN p.next_refresh_at ELSE now() END
		FROM feed_aliases a WHERE a.url = $1 AND a.podcast_id = p.id RETURNING p.id`

func (s store) resubscribe(ctx context.Context, address string) (int64, error) {
	var id int64
	err := s.withFeedWriter(ctx, func() error {
		return s.db.QueryRow(ctx, resubscribeSQL, address).Scan(&id)
	})
	return id, err
}

func migrateFeedAliases(ctx context.Context, tx pgx.Tx) error {
	type alias struct {
		URL       string
		PodcastID int64
	}
	rows, err := tx.Query(ctx, "SELECT url, podcast_id FROM feed_aliases ORDER BY podcast_id, url")
	if err != nil {
		return err
	}
	aliases, err := pgx.CollectRows(rows, pgx.RowToStructByPos[alias])
	if err != nil {
		return err
	}
	var batch pgx.Batch
	for _, a := range aliases {
		u, err := feedURL(a.URL)
		if err == nil && u.String() != a.URL {
			batch.Queue("INSERT INTO feed_aliases (url, podcast_id) VALUES ($1,$2) ON CONFLICT DO NOTHING", u.String(), a.PodcastID)
		}
	}
	return tx.SendBatch(ctx, &batch).Close()
}

func (s store) feedTarget(ctx context.Context, id int64) (feedTarget, error) {
	var f feedTarget
	err := s.db.QueryRow(ctx, `SELECT id, feed_url, etag, last_modified, failures, fetch_generation
		FROM podcasts WHERE id = $1`, id).Scan(&f.ID, &f.URL, &f.ETag, &f.LastModified, &f.Failures, &f.Generation)
	return f, err
}

func (s store) addFeed(ctx context.Context, original string, result feedResponse, next time.Time) (int64, bool, error) {
	var id int64
	var added bool
	err := s.withFeedLock(ctx, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `SELECT podcast_id FROM feed_aliases WHERE url IN ($1,$2)
			ORDER BY (url = $1) DESC LIMIT 1`, original, result.url).Scan(&id)
		switch {
		case err == nil:
			if _, err := tx.Exec(ctx, "UPDATE podcasts SET subscribed = true WHERE id = $1", id); err != nil {
				return err
			}
		case errors.Is(err, pgx.ErrNoRows):
			if err := tx.QueryRow(ctx, "INSERT INTO podcasts (feed_url) VALUES ($1) RETURNING id", result.url).Scan(&id); err != nil {
				return err
			}
			if err := saveFeed(ctx, tx, id, result, next); err != nil {
				return err
			}
			added = true
		default:
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO feed_aliases (url, podcast_id) VALUES ($1,$3), ($2,$3)
			ON CONFLICT DO NOTHING`, original, result.url, id)
		return err
	})
	return id, added, err
}

func (s store) applyRefresh(ctx context.Context, target feedTarget, result feedResponse, next time.Time) error {
	return s.withFeedLock(ctx, func(tx pgx.Tx) error {
		var generation int64
		if err := tx.QueryRow(ctx, "SELECT fetch_generation FROM podcasts WHERE id = $1 FOR UPDATE", target.ID).Scan(&generation); err != nil {
			return err
		}
		if generation != target.Generation {
			return nil
		}
		if result.url != target.URL {
			var owner int64
			err := tx.QueryRow(ctx, `INSERT INTO feed_aliases (url, podcast_id) VALUES ($1,$2)
				ON CONFLICT (url) DO UPDATE SET url = EXCLUDED.url RETURNING podcast_id`, result.url, target.ID).Scan(&owner)
			if err != nil {
				return err
			}
			if owner != target.ID {
				return feedError("feed redirects to another known podcast")
			}
		}
		return saveFeed(ctx, tx, target.ID, result, next)
	})
}

func saveFeed(ctx context.Context, tx pgx.Tx, id int64, result feedResponse, next time.Time) error {
	_, err := tx.Exec(ctx, `UPDATE podcasts SET feed_url = $2, etag = $3, last_modified = $4, next_refresh_at = $5,
		last_success_at = now(), last_error = NULL, failures = 0, fetch_generation = fetch_generation + 1 WHERE id = $1`,
		id, result.url, result.etag, result.lastModified, next)
	if err != nil || result.document == nil {
		return err
	}
	f := result.document
	_, err = tx.Exec(ctx, `UPDATE podcasts SET title = $2, author = $3, description = $4, image_url = $5, link = $6 WHERE id = $1`,
		id, f.Title, f.Author, f.Description, f.ImageURL, f.Link)
	if err != nil {
		return err
	}
	return saveEpisodes(ctx, tx, id, f.episodes)
}

type episodeIdentity struct {
	ID           int64
	GUID         string
	EnclosureURL string
}

func episodeIdentities(ctx context.Context, tx pgx.Tx, podcastID int64) ([]episodeIdentity, error) {
	rows, err := tx.Query(ctx, `SELECT id, guid, enclosure_url FROM episodes WHERE podcast_id = $1
		ORDER BY removed_from_feed, id`, podcastID)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowToStructByPos[episodeIdentity])
}

func saveEpisodes(ctx context.Context, tx pgx.Tx, podcastID int64, incoming []episodeDetail) error {
	existing, err := episodeIdentities(ctx, tx, podcastID)
	if err != nil {
		return err
	}
	counts := make(map[string]int)
	repeated := make(map[[2]string]bool)
	for _, e := range incoming {
		key := [2]string{e.GUID, e.EnclosureURL}
		if e.GUID != "" && !repeated[key] {
			repeated[key] = true
			counts[e.GUID]++
		}
	}
	ambiguous, err := rememberAmbiguousGUIDs(ctx, tx, podcastID, counts)
	if err != nil {
		return err
	}
	byGUID := make(map[string]*episodeIdentity)
	byURL := make(map[string]*episodeIdentity)
	guidlessByURL := make(map[string]*episodeIdentity)
	for i := range existing {
		e := &existing[i]
		if _, exists := byURL[e.EnclosureURL]; !exists {
			byURL[e.EnclosureURL] = e
		}
		if e.GUID == "" {
			if _, exists := guidlessByURL[e.EnclosureURL]; !exists {
				guidlessByURL[e.EnclosureURL] = e
			}
		} else {
			byGUID[e.GUID] = e
		}
	}
	estimates := estimatedPublications(incoming)
	var batch pgx.Batch
	seen := make(map[*episodeIdentity]bool)
	live := make([]int64, 0, len(incoming))
	added := 0
	changed := false
	for i, e := range incoming {
		if ambiguous[e.GUID] {
			e.GUID = ""
		}
		match := byGUID[e.GUID]
		if match == nil {
			if e.GUID == "" {
				match = byURL[e.EnclosureURL]
			} else {
				match = guidlessByURL[e.EnclosureURL]
			}
		}
		if seen[match] {
			continue
		}
		if e.GUID == "" && match != nil {
			e.GUID = match.GUID
		}
		var published *time.Time
		if e.PublishedAt != nil {
			published = &e.PublishedAt.Time
		}
		args := []any{e.GUID, e.Title, published, e.DurationSeconds, e.EnclosureURL, e.EnclosureType,
			e.EnclosureLength, e.Link, e.ImageURL, e.Description, estimates[i]}
		if match == nil {
			added++
			if len(existing)+added > maxStoredFeedEpisodes {
				return errStoredEpisodeLimit
			}
			match = &episodeIdentity{}
			position := len(live)
			live = append(live, 0)
			batch.Queue(`INSERT INTO episodes (guid, title, published_at, duration_s, enclosure_url, enclosure_type,
				enclosure_length, link, image_url, description, estimated_publication, podcast_id)
				VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) RETURNING id`, append(args, podcastID)...).
				QueryRow(func(row pgx.Row) error {
					return row.Scan(&live[position])
				})
			changed = true
		} else {
			batch.Queue(`UPDATE episodes SET guid = $1, title = $2, published_at = $3, duration_s = $4,
				enclosure_url = $5, enclosure_type = $6, enclosure_length = $7, link = $8, image_url = $9,
				description = $10, estimated_publication = $11, removed_from_feed = false WHERE id = $12 AND
				(removed_from_feed OR ROW(guid, title, published_at, duration_s, enclosure_url, enclosure_type,
				enclosure_length, link, image_url, description, estimated_publication) IS DISTINCT FROM
				ROW($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11))`, append(args, match.ID)...).
				Exec(func(tag pgconn.CommandTag) error {
					changed = changed || tag.RowsAffected() != 0
					return nil
				})
			live = append(live, match.ID)
		}
		seen[match] = true
		match.GUID = e.GUID
		byURL[e.EnclosureURL] = match
		if e.GUID == "" {
			guidlessByURL[e.EnclosureURL] = match
		} else {
			byGUID[e.GUID] = match
			if guidlessByURL[e.EnclosureURL] == match {
				delete(guidlessByURL, e.EnclosureURL)
			}
		}
	}
	if err := tx.SendBatch(ctx, &batch).Close(); err != nil {
		return err
	}
	tag, err := tx.Exec(ctx, `UPDATE episodes SET removed_from_feed = true
		WHERE podcast_id = $1 AND NOT removed_from_feed AND NOT (id = ANY($2))`, podcastID, live)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `UPDATE podcasts SET feed_episode_order = $2, episodes_version = episodes_version + 1
		WHERE id = $1 AND ($3 OR feed_episode_order IS DISTINCT FROM $2)`, podcastID, live, changed || tag.RowsAffected() != 0)
	return err
}

func rememberAmbiguousGUIDs(ctx context.Context, tx pgx.Tx, podcastID int64, counts map[string]int) (map[string]bool, error) {
	rows, err := tx.Query(ctx, "SELECT guid_hash FROM ambiguous_feed_guids WHERE podcast_id = $1", podcastID)
	if err != nil {
		return nil, err
	}
	hashes, err := pgx.CollectRows(rows, pgx.RowTo[[]byte])
	if err != nil {
		return nil, err
	}
	known := make(map[string]bool, len(hashes))
	for _, hash := range hashes {
		known[string(hash)] = true
	}
	ambiguous := make(map[string]bool)
	var newHashes [][]byte
	for guid, count := range counts {
		if guid == "" {
			continue
		}
		hash := sha256.Sum256([]byte(guid))
		if known[string(hash[:])] {
			ambiguous[guid] = true
		} else if count > 1 {
			ambiguous[guid] = true
			newHashes = append(newHashes, hash[:])
		}
	}
	if len(newHashes) > 0 {
		if len(known)+len(newHashes) > maxStoredFeedEpisodes {
			return nil, feedError("podcast has reached the ambiguous GUID limit")
		}
		_, err = tx.Exec(ctx, `INSERT INTO ambiguous_feed_guids (podcast_id, guid_hash)
			SELECT $1, unnest($2::bytea[]) ON CONFLICT DO NOTHING`, podcastID, newHashes)
	}
	return ambiguous, err
}

func estimatedPublications(incoming []episodeDetail) []*time.Time {
	estimates := make([]*time.Time, len(incoming))
	var nearest *time.Time
	for i := len(incoming) - 1; i >= 0; i-- {
		if published := incoming[i].PublishedAt; published != nil {
			nearest = &published.Time
		} else {
			estimates[i] = nearest
		}
	}
	nearest = nil
	for i, e := range incoming {
		if e.PublishedAt != nil {
			nearest = &e.PublishedAt.Time
		} else if estimates[i] == nil {
			estimates[i] = nearest
		}
	}
	return estimates
}
