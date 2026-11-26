package main

import (
	"errors"
	"fmt"
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
	feed, err := parseFeed(t.Context(), fixture(t, "first.xml"), base)
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
	changed, err := parseFeed(t.Context(), fixture(t, "changed.xml"), base)
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

func TestPlainTextLimitsInputAndKeepsLinks(t *testing.T) {
	base, _ := url.Parse("https://example.invalid/episodes")
	source := `<p> Read <a href="/notes">the <b>notes</b></a>.</p>
		<template>hidden <template>also hidden</template></template><style>hidden</style><script>hidden</script>
		<a href="/sky">/sky</a><br><!--` + strings.Repeat("x", maxDescriptionBytes) + "-->too far"
	want := "Read the notes (https://example.invalid/notes).\nhttps://example.invalid/sky"
	if text := plainText(source, base); text != want {
		t.Fatalf("description %q, want %q", text, want)
	}
}

func TestParseFeedLimits(t *testing.T) {
	base, _ := url.Parse("https://example.invalid/feed")
	for _, tc := range []struct {
		name string
		body string
		want feedError
	}{
		{"nesting", `<rss xmlns:x="urn:fixture"><channel><title>Fixture</title><x:category>` +
			strings.Repeat("<x:a>", maxFeedDepth) + strings.Repeat("</x:a>", maxFeedDepth) + "</x:category></channel></rss>", errFeedTooDeep},
		{"controls and nesting", "<rss><channel><title>Fi\x01xture</title>" +
			strings.Repeat("<a>", maxFeedDepth) + strings.Repeat("</a>", maxFeedDepth) + "</channel></rss>", errFeedTooDeep},
		{"XML items", "<rss><channel><title>Fixture</title>" +
			strings.Repeat("<ITEM/>", maxFeedItems+1) + "</channel></rss>", errTooManyItems},
		{"JSON items", `{"title":"Fixture","items":[` +
			strings.Repeat("{},", maxFeedItems) + "{}]}", errTooManyItems},
		{"invalid JSON prefix", "\x01" + `{"title":"Fixture","items":[{}]}`, errUnusableFeed},
		{"null JSON item", `{"title":"Fixture","items":[null]}`, errUnusableFeed},
		{"body size", strings.Repeat(" ", maxFeedBytes+1), errFeedTooLarge},
		{"Atom markup", `<feed xml:base="https://example.invalid/"><title>Fixture</title><subtitle type="html"><![CDATA[` +
			strings.Repeat("<p>Line</p>", 400) + "]]></subtitle></feed>", errAtomMarkup},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := parseFeed(t.Context(), []byte(tc.body), base); !errors.Is(err, tc.want) {
				t.Fatalf("got %v, want %v", err, tc.want)
			}
		})
	}
}

func TestParseAtomHTMLWithoutBase(t *testing.T) {
	base, _ := url.Parse("https://example.invalid/feed")
	html := strings.Repeat(`<p>Read the <a href="/notes">notes</a> for this episode.</p>`, 20)
	for name, content := range map[string]string{
		"escaped": strings.NewReplacer("<", "&lt;", ">", "&gt;").Replace(html),
		"CDATA":   "<![CDATA[" + html + "]]>",
	} {
		t.Run(name, func(t *testing.T) {
			var body strings.Builder
			body.WriteString(`<feed xmlns="http://www.w3.org/2005/Atom"><title>Fixture</title>`)
			for i := range 100 {
				fmt.Fprintf(&body, `<entry><id>%d</id><title>Episode</title><content type="html">%s</content>
					<link rel="enclosure" type="audio/mpeg" href="/audio/%d.mp3"/></entry>`, i, content, i)
			}
			body.WriteString("</feed>")
			f, err := parseFeed(t.Context(), []byte(body.String()), base)
			if err != nil || len(f.episodes) != 100 ||
				!strings.Contains(f.episodes[99].Description, "notes (https://example.invalid/notes)") {
				t.Fatalf("valid Atom HTML feed was not parsed: %v", err)
			}
		})
	}
}

func TestParseJSONFeedNUL(t *testing.T) {
	base, _ := url.Parse("https://example.invalid/feed")
	for _, value := range []string{`"Episode\u0000"`, `"Episode\\\u0000"`} {
		body := fmt.Sprintf(`{"title":"Fixture","items":[{"id":%s,"title":"Episode","attachments":[{"url":"/audio.mp3"}]}]}`, value)
		if _, err := parseFeed(t.Context(), []byte(body), base); err != errUnusableFeed {
			t.Errorf("got %v, want %v", err, errUnusableFeed)
		}
	}
	body := `{"title":"Fixture","items":[{"id":"Episode\\u0000","attachments":[{"url":"/audio.mp3"}]}]}`
	f, err := parseFeed(t.Context(), []byte(body), base)
	if err != nil || len(f.episodes) != 1 || f.episodes[0].GUID != `Episode\u0000` {
		t.Fatalf("literal backslash in JSON feed was not preserved: %v", err)
	}
}

func BenchmarkParseLargeFeed(b *testing.B) {
	base, _ := url.Parse("https://example.invalid/feed")
	for _, mib := range []int{30, 61} {
		b.Run(fmt.Sprintf("%dMiB", mib), func(b *testing.B) {
			var feed strings.Builder
			feed.Grow(mib << 20)
			feed.WriteString(`<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><title>Fixture</title>`)
			notes := strings.Repeat(`<p>Episode notes with a <a href="https://example.invalid/notes">link</a> and more text.</p>`, 120)
			items := 0
			for feed.Len() < (mib << 20) {
				fmt.Fprintf(&feed, `<item><guid>e%d</guid><title>Episode %d</title><pubDate>Thu, 26 Nov 2026 09:15:00 GMT</pubDate>
					<description><![CDATA[%s]]></description><content:encoded><![CDATA[%s]]></content:encoded><itunes:summary><![CDATA[%s]]></itunes:summary>
					<enclosure url="/audio/%d.mp3" type="audio/mpeg"/></item>`, items, items, notes, notes, notes, items)
				items++
			}
			feed.WriteString("</channel></rss>")
			body := []byte(feed.String())
			b.SetBytes(int64(len(body)))
			b.ReportAllocs()
			for b.Loop() {
				f, err := parseFeed(b.Context(), body, base)
				if err != nil || len(f.episodes) != items {
					b.Fatalf("parse of %d items: %v", items, err)
				}
			}
		})
	}
}

func TestParseFeedAtomAndJSON(t *testing.T) {
	base, _ := url.Parse("https://example.invalid/feed")
	for _, body := range []string{
		`<feed xmlns="http://www.w3.org/2005/Atom" xml:base="https://example.invalid/show/">
			<title>Fixture</title><entry><id>fixture</id><title>Episode</title>
			<summary type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><a href="notes">Notes</a></div></summary>
			<link rel="enclosure" type="audio/mpeg" href="audio.mp3"/>
			</entry></feed>`,
		`{"version":"https://jsonfeed.org/version/1.1","title":"Fixture","items":[{"id":"fixture","title":"Episode",
			"content_html":"<a href=\"/show/notes\">Notes</a>","attachments":[{"url":"/show/audio.mp3","mime_type":"audio/mpeg"}]}]}`,
	} {
		f, err := parseFeed(t.Context(), []byte(body), base)
		if err != nil || len(f.episodes) != 1 ||
			f.episodes[0].Description != "Notes (https://example.invalid/show/notes)" ||
			f.episodes[0].EnclosureURL != "https://example.invalid/show/audio.mp3" {
			t.Fatalf("feed %+v, %v", f, err)
		}
	}
}

func TestParseFeedRepairsInvalidUTF8(t *testing.T) {
	base, _ := url.Parse("https://example.invalid/feed")
	for _, tc := range []struct{ declaration, want string }{
		{"", "One \uFFFD Two"},
		{`<?xml version="1.0" encoding="UTF-8"?>`, "One \uFFFD Two"},
		{`<?xml version="1.0" encoding="windows-1250"?>`, "One š Two"},
	} {
		body := tc.declaration + "<rss><channel><title>Fixture</title><description><![CDATA[One \x9a Two]]></description></channel></rss>"
		f, err := parseFeed(t.Context(), []byte(body), base)
		if err != nil || f.Description != tc.want {
			t.Errorf("declaration %q: feed %+v, error %v, want %q", tc.declaration, f, err, tc.want)
		}
	}
}

func TestParseFeedSelectsMediaEnclosures(t *testing.T) {
	base, _ := url.Parse("https://example.invalid/feed")
	body := `<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>Fixture</title>
		<item><title>With image</title><enclosure url="/cover.png" type="image/png"/>
			<enclosure url="/listen" type="Audio/MPEG; bitrate=96"/><itunes:duration>00:00</itunes:duration></item>
		<item><title>Image only</title><enclosure url="/cover.png" type="image/png"/></item>
		<item><title>Image without type</title><enclosure url="/cover.webp"/></item>
		<item><title>Unknown type</title><enclosure url="/notes.html" type="text/html"/>
			<enclosure url="/opaque" type="application/octet-stream"/><enclosure url="/song.MP3?format=v1" type="application/octet-stream"/></item>
		<item><title>Opaque</title><enclosure url="/opaque" type="application/octet-stream"/></item>
		</channel></rss>`
	f, err := parseFeed(t.Context(), []byte(body), base)
	if err != nil {
		t.Fatal(err)
	}
	if episodes := f.episodes; len(episodes) != 3 ||
		episodes[0].EnclosureURL != "https://example.invalid/listen" || episodes[0].DurationSeconds != nil ||
		episodes[1].EnclosureURL != "https://example.invalid/song.MP3?format=v1" ||
		episodes[2].EnclosureURL != "https://example.invalid/opaque" {
		t.Fatalf("unexpected enclosures: %+v", episodes)
	}
}
