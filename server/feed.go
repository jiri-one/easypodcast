package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"os"
	"path"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/mmcdole/gofeed"
)

const maxFeedBytes = 64 << 20
const largeFeedBytes = 8 << 20

const (
	errInvalidFeedURL  = feedError("feed_url must be an HTTP or HTTPS URL without credentials")
	errInvalidRedirect = feedError("invalid feed redirect")
	errPrivateFeed     = feedError("feed address is not public")
	errFeedTimeout     = feedError("feed request timed out")
)

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
	host, port := u.Hostname(), u.Port()
	name, zone, zoned := strings.Cut(host, "%")
	host = strings.ToLower(name)
	if zoned {
		host += "%" + zone
	}
	if port == "80" && u.Scheme == "http" || port == "443" && u.Scheme == "https" {
		port = ""
	}
	switch {
	case port != "":
		u.Host = net.JoinHostPort(host, port)
	case strings.HasPrefix(u.Host, "["):
		u.Host = "[" + host + "]"
	default:
		u.Host = host
	}
	u.Fragment = ""
	u.RawFragment = ""
	return u, nil
}

func feedHTTPClient() http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	dialer := net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}
	if os.Getenv("EASYPODCAST_ALLOW_PRIVATE_FEEDS") != "true" {
		dialer.Control = publicFeedAddress
	}
	transport.DialContext = dialer.DialContext
	return http.Client{Transport: transport}
}

var nonPublicFeedNetworks = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"),
	netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("240.0.0.0/4"),
	netip.MustParsePrefix("::/96"),
	netip.MustParsePrefix("64:ff9b::/96"),
	netip.MustParsePrefix("64:ff9b:1::/48"),
	netip.MustParsePrefix("2002::/16"),
}

func publicFeedAddress(_, address string, _ syscall.RawConn) error {
	endpoint, err := netip.ParseAddrPort(address)
	if err != nil {
		return errPrivateFeed
	}
	ip := endpoint.Addr().Unmap()
	if !ip.IsGlobalUnicast() || ip.IsPrivate() {
		return errPrivateFeed
	}
	for _, network := range nonPublicFeedNetworks {
		if network.Contains(ip) {
			return errPrivateFeed
		}
	}
	return nil
}

func feedTransportError(err error, fallback feedError) feedError {
	var network net.Error
	var dns *net.DNSError
	var cert *tls.CertificateVerificationError
	var hostname x509.HostnameError
	var unknownCA x509.UnknownAuthorityError
	var invalidCert x509.CertificateInvalidError
	switch {
	case errors.Is(err, errInvalidRedirect):
		return errInvalidRedirect
	case errors.Is(err, errPrivateFeed):
		return errPrivateFeed
	case errors.Is(err, context.DeadlineExceeded), errors.As(err, &network) && network.Timeout():
		return errFeedTimeout
	case errors.As(err, &dns):
		if dns.IsNotFound {
			return "feed host not found"
		}
		return "feed DNS lookup failed"
	case errors.As(err, &cert), errors.As(err, &hostname), errors.As(err, &unknownCA), errors.As(err, &invalidCert):
		return "feed TLS certificate not accepted"
	case errors.Is(err, syscall.ECONNREFUSED):
		return "feed connection refused"
	case errors.Is(err, syscall.ECONNRESET):
		return "feed connection reset"
	default:
		return fallback
	}
}

func (r *refresher) fetch(ctx context.Context, target feedTarget) (feedResponse, error) {
	select {
	case r.slots <- struct{}{}:
		defer func() { <-r.slots }()
	case <-ctx.Done():
		return feedResponse{}, feedTransportError(ctx.Err(), "feed request canceled")
	}
	ctx, cancel := context.WithTimeout(ctx, fetchTimeout)
	defer cancel()
	canonical := target.URL
	permanent := true
	client := r.client
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		u, err := feedURL(req.URL.String())
		if len(via) >= 10 || err != nil {
			return errInvalidRedirect
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
		return feedResponse{}, feedTransportError(err, "feed request failed")
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
	result.document, err = r.parseFeedBody(ctx, resp)
	return result, err
}

func (r *refresher) parseFeedBody(ctx context.Context, resp *http.Response) (*feedDocument, error) {
	if resp.ContentLength > maxFeedBytes {
		return nil, errFeedTooLarge
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, largeFeedBytes+1))
	if err != nil {
		return nil, feedTransportError(err, "could not read feed")
	}
	if len(body) > largeFeedBytes {
		select {
		case r.large <- struct{}{}:
			defer func() { <-r.large }()
		case <-ctx.Done():
			return nil, feedTransportError(ctx.Err(), "feed request canceled")
		}
		buffer := bytes.NewBuffer(body)
		if _, err := buffer.ReadFrom(io.LimitReader(resp.Body, int64(maxFeedBytes+1-len(body)))); err != nil {
			return nil, feedTransportError(err, "could not read feed")
		}
		body = buffer.Bytes()
	}
	return parseFeed(ctx, body, resp.Request.URL)
}

func parseFeed(ctx context.Context, body []byte, base *url.URL) (*feedDocument, error) {
	f, err := boundedFeed(ctx, body)
	if err != nil {
		return nil, err
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
		if err := ctx.Err(); err != nil {
			return nil, feedTransportError(err, "feed request canceled")
		}
		enclosure, address := mediaEnclosure(base, item.Enclosures)
		if enclosure == nil {
			continue
		}
		description := item.Description
		if item.Content != "" {
			description = item.Content
		}
		e := episodeDetail{episode: episode{
			GUID: strings.TrimSpace(item.GUID), Title: item.Title, PublishedAt: nullableTimestamp(item.PublishedParsed),
			EnclosureURL: address, EnclosureType: nonempty(enclosure.Type),
			EnclosureLength: nonnegativeInt(enclosure.Length), Link: resolveLink(base, item.Link),
		}, Description: plainText(description, base)}
		if item.Image != nil {
			e.ImageURL = resolveLink(base, item.Image.URL)
		}
		if item.ITunesExt != nil {
			e.DurationSeconds = durationSeconds(item.ITunesExt.Duration)
		}
		result.episodes = append(result.episodes, e)
	}
	if err := ctx.Err(); err != nil {
		return nil, feedTransportError(err, "feed request canceled")
	}
	return result, nil
}

func mediaEnclosure(base *url.URL, enclosures []*gofeed.Enclosure) (*gofeed.Enclosure, string) {
	var fallback *gofeed.Enclosure
	var fallbackURL string
	for _, enclosure := range enclosures {
		address := resolveLink(base, enclosure.URL)
		if address == nil {
			continue
		}
		mediaType, _, err := mime.ParseMediaType(enclosure.Type)
		if err != nil && mediaType == "" {
			mediaType = strings.ToLower(strings.TrimSpace(enclosure.Type))
		}
		if strings.HasPrefix(mediaType, "audio/") || strings.HasPrefix(mediaType, "video/") ||
			mediaType == "application/ogg" {
			return enclosure, *address
		}
		resolved, _ := url.Parse(*address)
		switch strings.ToLower(path.Ext(resolved.Path)) {
		case ".mp3", ".m4a", ".m4b", ".m4v", ".aac", ".ogg", ".oga", ".opus", ".flac", ".wav", ".mp4", ".webm", ".mov":
			return enclosure, *address
		case ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".avif", ".bmp", ".tif", ".tiff", ".html", ".htm", ".txt":
			continue
		}
		if fallback == nil && !strings.HasPrefix(mediaType, "image/") && !strings.HasPrefix(mediaType, "text/") {
			fallback, fallbackURL = enclosure, *address
		}
	}
	return fallback, fallbackURL
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
		n := nonnegativeInt(value)
		if n == nil || *n == 0 {
			return nil
		}
		return n
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
	if seconds == 0 {
		return nil
	}
	return &seconds
}
