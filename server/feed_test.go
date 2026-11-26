package main

import (
	"net/url"
	"os"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

func fixture(t *testing.T, file string) []byte {
	t.Helper()
	data, err := os.ReadFile("testdata/" + file)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestParseFeed(t *testing.T) {
	base, _ := url.Parse("https://example.invalid/feeds/cloudberry.xml")
	feed, err := parseFeed(fixture(t, "first.xml"), base)
	if err != nil {
		t.Fatal(err)
	}
	if feed.Title != "Cloudberry Signal" || feed.Author != "Studio Lantern" ||
		feed.Description != "Notes from the studio (https://example.invalid/studio)." {
		t.Fatalf("feed metadata: %+v", feed.podcast)
	}
	if len(feed.episodes) != 2 {
		t.Fatalf("got %d episodes", len(feed.episodes))
	}
	copper, paper := feed.episodes[0], feed.episodes[1]
	if copper.PublishedAt == nil || !copper.PublishedAt.Equal(time.Date(2026, 11, 26, 9, 15, 0, 0, time.UTC)) {
		t.Fatalf("odd date: %v", copper.PublishedAt)
	}
	if copper.DurationSeconds == nil || *copper.DurationSeconds != 3842 ||
		copper.EnclosureURL != "https://example.invalid/feeds/audio/copper.mp3" {
		t.Fatalf("copper: %+v", copper)
	}
	if copper.Description != "First & bright\nRead the notes (https://example.invalid/notes).\nhttps://example.invalid/sky" {
		t.Fatalf("description: %q", copper.Description)
	}
	if paper.GUID != "" || paper.PublishedAt != nil || paper.EnclosureURL != "https://example.invalid/audio/paper.mp3" {
		t.Fatalf("paper: %+v", paper)
	}
	changed, err := parseFeed(fixture(t, "changed.xml"), base)
	if err != nil || changed.episodes[0].GUID != copper.GUID || changed.episodes[0].EnclosureURL == copper.EnclosureURL {
		t.Fatalf("changed feed: %+v, %v", changed, err)
	}
}

func TestPlainTextCharacterLimit(t *testing.T) {
	base, _ := url.Parse("https://example.invalid/")
	text := plainText("<p>"+strings.Repeat("ě", 20_001)+"</p>", base)
	if utf8.RuneCountInString(text) != 20_000 || !utf8.ValidString(text) {
		t.Fatalf("unexpected truncation at %d bytes", len(text))
	}
}
