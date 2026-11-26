package main

import (
	"context"
	"strings"
	"unicode"

	"github.com/jackc/pgx/v5"
	"golang.org/x/text/unicode/norm"
)

func normalizeSearchText(text string) string {
	folded := strings.Map(func(r rune) rune {
		if unicode.Is(unicode.Mn, r) {
			return -1
		}
		return unicode.ToLower(r)
	}, norm.NFD.String(text))
	return norm.NFC.String(folded)
}

func episodeSearchText(title, description string) string {
	return normalizeSearchText(title + " " + description)
}

func backfillEpisodeSearch(ctx context.Context, tx pgx.Tx) error {
	const batchSize = 256
	type source struct {
		ID          int64
		Title       string
		Description string
	}
	var cursor int64
	ids := make([]int64, batchSize)
	texts := make([]string, batchSize)
	for {
		rows, err := tx.Query(ctx, `SELECT id, title, description FROM episodes WHERE id > $1
			ORDER BY id LIMIT $2`, cursor, batchSize)
		if err != nil {
			return err
		}
		batch, err := pgx.CollectRows(rows, pgx.RowToStructByPos[source])
		if err != nil {
			return err
		}
		if len(batch) == 0 {
			break
		}
		for i, e := range batch {
			ids[i], texts[i] = e.ID, episodeSearchText(e.Title, e.Description)
		}
		if _, err := tx.Exec(ctx, `UPDATE episodes e SET search_text = batch.text
			FROM unnest($1::bigint[], $2::text[]) AS batch(id, text) WHERE e.id = batch.id`,
			ids[:len(batch)], texts[:len(batch)]); err != nil {
			return err
		}
		cursor = batch[len(batch)-1].ID
	}
	_, err := tx.Exec(ctx, `ALTER TABLE episodes ALTER COLUMN search_text SET NOT NULL`)
	return err
}

func (s store) searchEpisodes(ctx context.Context, podcastID int64, words []string) ([]int64, error) {
	if err := s.requirePodcast(ctx, podcastID); err != nil {
		return nil, err
	}
	rows, err := s.db.Query(ctx, "SELECT id"+episodeListFrom+`
		AND NOT EXISTS (SELECT FROM unnest($2::text[]) AS term(word) WHERE strpos(search_text, term.word) = 0)`+
		episodeListOrder+" LIMIT 200", podcastID, words)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[int64])
}

func (s store) searchAllEpisodes(ctx context.Context, words []string) ([]int64, error) {
	rows, err := s.db.Query(ctx, `SELECT id FROM episodes
		WHERE podcast_id IN (SELECT id FROM podcasts WHERE subscribed)
		AND NOT EXISTS (SELECT FROM unnest($1::text[]) AS term(word) WHERE strpos(search_text, term.word) = 0)
		ORDER BY published_at DESC NULLS LAST, id DESC LIMIT 100`, words)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, pgx.RowTo[int64])
}
