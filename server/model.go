package main

import (
	"encoding/json"
	"time"
)

type timestamp struct {
	time.Time
}

const timestampLayout = "2006-01-02T15:04:05.000Z"

func (t timestamp) MarshalJSON() ([]byte, error) {
	return t.UTC().AppendFormat(nil, `"`+timestampLayout+`"`), nil
}

type podcast struct {
	ID              int64      `json:"id"`
	FeedURL         string     `json:"feed_url"`
	Title           string     `json:"title"`
	Author          string     `json:"author"`
	Description     string     `json:"description"`
	ImageURL        *string    `json:"image_url"`
	Link            *string    `json:"link"`
	Subscribed      bool       `json:"subscribed"`
	EpisodeCount    int64      `json:"episode_count"`
	PlayedCount     int64      `json:"played_count"`
	EpisodesVersion string     `json:"episodes_version"`
	LastSuccessAt   *timestamp `json:"last_success_at"`
	LastError       *string    `json:"last_error"`
}

type episode struct {
	ID              int64      `json:"id"`
	PodcastID       int64      `json:"podcast_id"`
	GUID            string     `json:"guid"`
	Title           string     `json:"title"`
	PublishedAt     *timestamp `json:"published_at"`
	DurationSeconds *int64     `json:"duration_s"`
	EnclosureURL    string     `json:"enclosure_url"`
	EnclosureType   *string    `json:"enclosure_type"`
	EnclosureLength *int64     `json:"enclosure_length"`
	Link            *string    `json:"link"`
	ImageURL        *string    `json:"image_url"`
	RemovedFromFeed bool       `json:"removed_from_feed"`
}

type episodeDetail struct {
	episode
	Description string `json:"description"`
}

type episodeState struct {
	EpisodeID  int64     `json:"episode_id"`
	PositionMS int64     `json:"position_ms"`
	Status     string    `json:"status"`
	DurationMS *int64    `json:"duration_ms"`
	UpdatedAt  timestamp `json:"updated_at"`
}

func (e *episodeState) UnmarshalJSON(data []byte) error {
	var fields struct {
		EpisodeID  *int64     `json:"episode_id"`
		PositionMS *int64     `json:"position_ms"`
		Status     *string    `json:"status"`
		DurationMS *int64     `json:"duration_ms"`
		UpdatedAt  *timestamp `json:"updated_at"`
	}
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	if fields.EpisodeID == nil || fields.PositionMS == nil || fields.Status == nil || fields.UpdatedAt == nil {
		return errInvalidState
	}
	*e = episodeState{
		EpisodeID: *fields.EpisodeID, PositionMS: *fields.PositionMS, Status: *fields.Status,
		DurationMS: fields.DurationMS, UpdatedAt: *fields.UpdatedAt,
	}
	return nil
}

type queue struct {
	EpisodeIDs []int64   `json:"episode_ids"`
	UpdatedAt  timestamp `json:"updated_at"`
}

type stateChange struct {
	Episodes         []episodeState `json:"episodes"`
	Queue            *queue         `json:"queue"`
	expectedServerID *string
	queueOnlyIfEmpty bool
}

type stateRevision struct {
	ServerID string `json:"server_id"`
	version  int64
}

type stateSnapshot struct {
	stateChange
	stateRevision
}

type stateResult struct {
	stateChange
	ServerID            string  `json:"server_id"`
	Unknown             []int64 `json:"unknown"`
	Future              []any   `json:"future"`
	queueEntriesWritten int
}
