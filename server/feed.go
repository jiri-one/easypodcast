package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/mmcdole/gofeed"
	"golang.org/x/net/html"
	"golang.org/x/net/html/atom"
)

const maxFeedBytes = 32 << 20

var errInvalidFeedURL = errors.New("feed_url must be an HTTP or HTTPS URL without credentials")

type feedError string

func (e feedError) Error() string { return string(e) }

type feedDocument struct {
	podcast
	episodes []episodeDetail
}

type feedResponse struct {
	url          string
	etag         string
	lastModified string
	document     *feedDocument
}

func feedURL(raw string) (*url.URL, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" || u.User != nil {
		return nil, errInvalidFeedURL
	}
	u.Fragment = ""
	u.RawFragment = ""
	return u, nil
}

func (r *refresher) fetch(ctx context.Context, target feedTarget) (feedResponse, error) {
	select {
	case r.slots <- struct{}{}:
		defer func() { <-r.slots }()
	case <-ctx.Done():
		return feedResponse{}, ctx.Err()
	}
	canonical := target.URL
	permanent := true
	client := r.client
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		u, err := feedURL(req.URL.String())
		if len(via) >= 10 || err != nil {
			return errors.New("invalid feed redirect")
		}
		code := req.Response.StatusCode
		permanent = permanent && (code == http.StatusMovedPermanently || code == http.StatusPermanentRedirect)
		if permanent {
			canonical = u.String()
		}
		return nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target.URL, nil)
	if err != nil {
		return feedResponse{}, feedError("invalid feed URL")
	}
	req.Header.Set("User-Agent", r.userAgent)
	if target.ETag != "" {
		req.Header.Set("If-None-Match", target.ETag)
	}
	if target.LastModified != "" {
		req.Header.Set("If-Modified-Since", target.LastModified)
	}
	resp, err := client.Do(req)
	if err != nil {
		return feedResponse{}, feedError("feed request failed")
	}
	defer resp.Body.Close()
	result := feedResponse{url: canonical, etag: resp.Header.Get("ETag"), lastModified: resp.Header.Get("Last-Modified")}
	if resp.StatusCode == http.StatusNotModified && (target.ETag != "" || target.LastModified != "") {
		if result.etag == "" {
			result.etag = target.ETag
		}
		if result.lastModified == "" {
			result.lastModified = target.LastModified
		}
		return result, nil
	}
	if resp.StatusCode != http.StatusOK {
		return feedResponse{}, feedError(fmt.Sprintf("feed returned HTTP %d", resp.StatusCode))
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxFeedBytes+1))
	if err != nil {
		return feedResponse{}, feedError("could not read feed")
	}
	if len(body) > maxFeedBytes {
		return feedResponse{}, feedError("feed is too large")
	}
	result.document, err = parseFeed(body, resp.Request.URL)
	return result, err
}

func parseFeed(body []byte, base *url.URL) (*feedDocument, error) {
	f, err := gofeed.NewParser().Parse(bytes.NewReader(body))
	if err != nil || f == nil || strings.TrimSpace(f.Title) == "" {
		return nil, feedError("response is not a usable feed")
	}
	result := &feedDocument{}
	result.Title = strings.TrimSpace(f.Title)
	result.Description = plainText(f.Description, base)
	result.Link = resolveLink(base, f.Link)
	if len(f.Authors) > 0 {
		result.Author = f.Authors[0].Name
	}
	if f.Image != nil {
		result.ImageURL = resolveLink(base, f.Image.URL)
	}
	for _, item := range f.Items {
		for _, enclosure := range item.Enclosures {
			address := resolveLink(base, enclosure.URL)
			if address == nil {
				continue
			}
			e := episodeDetail{episode: episode{
				GUID: strings.TrimSpace(item.GUID), Title: item.Title, PublishedAt: nullableTimestamp(item.PublishedParsed),
				EnclosureURL: *address, EnclosureType: nonempty(enclosure.Type),
				EnclosureLength: nonnegativeInt(enclosure.Length), Link: resolveLink(base, item.Link),
			}, Description: plainText(item.Description, base)}
			if item.Content != "" {
				e.Description = plainText(item.Content, base)
			}
			if item.Image != nil {
				e.ImageURL = resolveLink(base, item.Image.URL)
			}
			if item.ITunesExt != nil {
				e.DurationSeconds = durationSeconds(item.ITunesExt.Duration)
			}
			result.episodes = append(result.episodes, e)
			break
		}
	}
	return result, nil
}

func resolveLink(base *url.URL, value string) *string {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil
	}
	ref, err := base.Parse(value)
	if err != nil || (ref.Scheme != "http" && ref.Scheme != "https") || ref.Hostname() == "" || ref.User != nil {
		return nil
	}
	resolved := ref.String()
	return &resolved
}

func nonempty(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func nonnegativeInt(s string) *int64 {
	n, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	if err != nil || n < 0 {
		return nil
	}
	return &n
}

func durationSeconds(value string) *int64 {
	parts := strings.Split(value, ":")
	if len(parts) == 1 {
		return nonnegativeInt(value)
	}
	if len(parts) > 3 {
		return nil
	}
	var seconds int64
	for i, part := range parts {
		n := nonnegativeInt(part)
		if n == nil || *n >= 60 && i > 0 || *n > 1<<31 {
			return nil
		}
		seconds = seconds*60 + *n
	}
	return &seconds
}

func plainText(source string, base *url.URL) string {
	context := &html.Node{Type: html.ElementNode, DataAtom: atom.Div, Data: "div"}
	nodes, err := html.ParseFragment(strings.NewReader(source), context)
	if err != nil {
		return ""
	}
	var out strings.Builder
	for _, node := range nodes {
		writeText(&out, node, base)
	}
	lines := strings.Split(out.String(), "\n")
	normalized := lines[:0]
	for _, line := range lines {
		if trimmed := strings.Join(strings.Fields(line), " "); trimmed != "" {
			normalized = append(normalized, trimmed)
		}
	}
	value := strings.Join(normalized, "\n")
	count := 0
	for offset := range value {
		if count == 20_000 {
			return value[:offset]
		}
		count++
	}
	return value
}

func writeText(out *strings.Builder, n *html.Node, base *url.URL) {
	if n.Type == html.TextNode {
		out.WriteString(n.Data)
		return
	}
	switch n.DataAtom {
	case atom.Script, atom.Style, atom.Template:
		return
	case atom.Br:
		out.WriteByte('\n')
		return
	case atom.A:
		var text strings.Builder
		for child := n.FirstChild; child != nil; child = child.NextSibling {
			writeText(&text, child, base)
		}
		label := strings.TrimSpace(text.String())
		for _, attr := range n.Attr {
			if attr.Key != "href" {
				continue
			}
			if link := resolveLink(base, attr.Val); link != nil {
				if label == "" {
					label = *link
				} else if label != *link && label != attr.Val {
					label += " (" + *link + ")"
				} else {
					label = *link
				}
			}
			break
		}
		out.WriteString(label)
		return
	}
	switch n.DataAtom {
	case atom.P, atom.Div, atom.Li, atom.H1, atom.H2, atom.H3, atom.H4, atom.H5, atom.H6, atom.Blockquote:
		out.WriteByte('\n')
		defer out.WriteByte('\n')
	}
	for child := n.FirstChild; child != nil; child = child.NextSibling {
		writeText(out, child, base)
	}
}
