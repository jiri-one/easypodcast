package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
)

const (
	directoryLimit    = 25
	directoryTimeout  = 8 * time.Second
	maxDirectoryBytes = 1 << 20
)

type directoryPodcast struct {
	FeedURL    string  `json:"feed_url"`
	Title      string  `json:"title"`
	Author     string  `json:"author"`
	ImageURL   *string `json:"image_url"`
	Subscribed bool    `json:"subscribed"`
}

func configuredDirectoryURL(value string) (*url.URL, error) {
	switch value {
	case "off":
		return nil, nil
	case "":
		value = "https://itunes.apple.com/search"
	}
	address, err := feedURL(value)
	if err != nil {
		return nil, errors.New("EASYPODCAST_DIRECTORY_URL must be an HTTP or HTTPS URL or off")
	}
	return address, nil
}

func (a *api) searchDirectory(w http.ResponseWriter, r *http.Request) {
	if a.refresh.directoryURL == nil {
		apiError(w, http.StatusNotFound, "podcast directory is off")
		return
	}
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	if utf8.RuneCountInString(query) < 2 {
		apiError(w, http.StatusBadRequest, "q must contain at least two characters")
		return
	}
	results, err := a.refresh.searchDirectory(r.Context(), query)
	if err != nil {
		if r.Context().Err() == nil {
			slog.Warn("Podcast directory request failed", "reason", err.Error())
		}
		apiError(w, http.StatusBadGateway, "podcast directory unavailable")
		return
	}
	if err := a.store.markDirectorySubscriptions(r.Context(), results); err != nil {
		storeError(w, r, err)
		return
	}
	jsonReply(w, r, http.StatusOK, results)
}

func (r *refresher) searchDirectory(ctx context.Context, query string) ([]directoryPodcast, error) {
	ctx, cancel := context.WithTimeout(ctx, directoryTimeout)
	defer cancel()
	address := *r.directoryURL
	params := address.Query()
	params.Set("term", query)
	params.Set("media", "podcast")
	params.Set("entity", "podcast")
	params.Set("limit", strconv.Itoa(directoryLimit))
	address.RawQuery = params.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address.String(), nil)
	if err != nil {
		return nil, errors.New("invalid directory URL")
	}
	req.Header.Set("User-Agent", r.userAgent)
	resp, err := r.client.Do(req)
	if err != nil {
		return nil, feedTransportError(err, "directory request failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxDirectoryBytes+1))
	if err != nil {
		return nil, feedTransportError(err, "could not read directory response")
	}
	if len(body) > maxDirectoryBytes {
		return nil, errors.New("response too large")
	}
	var response struct {
		Results []struct {
			FeedURL  string `json:"feedUrl"`
			Title    string `json:"collectionName"`
			Author   string `json:"artistName"`
			ImageURL string `json:"artworkUrl100"`
		} `json:"results"`
	}
	if err := json.Unmarshal(body, &response); err != nil || response.Results == nil {
		return nil, errors.New("invalid response")
	}
	results := make([]directoryPodcast, 0, min(directoryLimit, len(response.Results)))
	seen := make(map[string]bool, cap(results))
	for _, item := range response.Results {
		feed, err := feedURL(item.FeedURL)
		title := strings.TrimSpace(item.Title)
		if err != nil || title == "" {
			continue
		}
		key := feed.String()
		if seen[key] {
			continue
		}
		seen[key] = true
		results = append(results, directoryPodcast{
			FeedURL:  key,
			Title:    title,
			Author:   strings.TrimSpace(item.Author),
			ImageURL: resolveLink(&url.URL{}, item.ImageURL),
		})
		if len(results) == directoryLimit {
			break
		}
	}
	return results, nil
}

func (s store) markDirectorySubscriptions(ctx context.Context, results []directoryPodcast) error {
	if len(results) == 0 {
		return nil
	}
	feeds := make([]string, len(results))
	for i, result := range results {
		feeds[i] = result.FeedURL
	}
	rows, err := s.db.Query(ctx, `SELECT a.url FROM feed_aliases a
		JOIN podcasts p ON p.id = a.podcast_id WHERE p.subscribed AND a.url = ANY($1)`, feeds)
	if err != nil {
		return err
	}
	subscribed, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	for i := range results {
		results[i].Subscribed = slices.Contains(subscribed, results[i].FeedURL)
	}
	return nil
}
