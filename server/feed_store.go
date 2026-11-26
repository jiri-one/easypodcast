package main

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

func (s store) resubscribe(ctx context.Context, address string) (int64, error) {
	var id int64
	err := s.db.QueryRow(ctx, `UPDATE podcasts p SET subscribed = true,
		next_refresh_at = CASE WHEN p.subscribed THEN p.next_refresh_at ELSE now() END
		FROM feed_aliases a WHERE a.url = $1 AND a.podcast_id = p.id RETURNING p.id`, address).Scan(&id)
	return id, err
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
	err := pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock($1)", feedLock); err != nil {
			return err
		}
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
	return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock($1)", feedLock); err != nil {
			return err
		}
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
	byGUID := make(map[string]episodeIdentity)
	byURL := make(map[string]episodeIdentity)
	guidlessByURL := make(map[string]episodeIdentity)
	for _, e := range existing {
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
	changed := false
	seen := make(map[int64]bool)
	live := make([]int64, 0, len(incoming))
	for _, e := range incoming {
		match := byGUID[e.GUID]
		if match.ID == 0 {
			if e.GUID == "" {
				match = byURL[e.EnclosureURL]
			} else {
				match = guidlessByURL[e.EnclosureURL]
			}
		}
		if seen[match.ID] {
			continue
		}
		if e.GUID == "" {
			e.GUID = match.GUID
		}
		var published *time.Time
		if e.PublishedAt != nil {
			published = &e.PublishedAt.Time
		}
		args := []any{e.GUID, e.Title, published, e.DurationSeconds, e.EnclosureURL, e.EnclosureType,
			e.EnclosureLength, e.Link, e.ImageURL, e.Description}
		id := match.ID
		if id == 0 {
			err := tx.QueryRow(ctx, `INSERT INTO episodes (guid, title, published_at, duration_s, enclosure_url,
				enclosure_type, enclosure_length, link, image_url, description, podcast_id)
				VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) RETURNING id`, append(args, podcastID)...).Scan(&id)
			if err != nil {
				return err
			}
			changed = true
		} else {
			tag, err := tx.Exec(ctx, `UPDATE episodes SET guid = $1, title = $2, published_at = $3, duration_s = $4,
				enclosure_url = $5, enclosure_type = $6, enclosure_length = $7, link = $8, image_url = $9,
				description = $10, removed_from_feed = false WHERE id = $11 AND
				(removed_from_feed OR ROW(guid, title, published_at, duration_s, enclosure_url, enclosure_type,
				enclosure_length, link, image_url, description) IS DISTINCT FROM
				ROW($1,$2,$3,$4,$5,$6,$7,$8,$9,$10))`, append(args, id)...)
			if err != nil {
				return err
			}
			changed = changed || tag.RowsAffected() != 0
		}
		seen[id] = true
		live = append(live, id)
		identity := episodeIdentity{id, e.GUID, e.EnclosureURL}
		byURL[e.EnclosureURL] = identity
		if e.GUID == "" {
			guidlessByURL[e.EnclosureURL] = identity
		} else {
			byGUID[e.GUID] = identity
			if guidlessByURL[e.EnclosureURL].ID == id {
				delete(guidlessByURL, e.EnclosureURL)
			}
		}
	}
	tag, err := tx.Exec(ctx, `UPDATE episodes SET removed_from_feed = true
		WHERE podcast_id = $1 AND NOT removed_from_feed AND NOT (id = ANY($2))`, podcastID, live)
	if err != nil {
		return err
	}
	if changed || tag.RowsAffected() != 0 {
		_, err = tx.Exec(ctx, "UPDATE podcasts SET episodes_version = episodes_version + 1 WHERE id = $1", podcastID)
	}
	return err
}
