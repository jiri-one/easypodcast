package main

import (
	"bytes"
	"context"
	"encoding/json"
	"encoding/xml"
	"errors"
	"io"
	"strings"
	"unicode/utf8"

	"github.com/mmcdole/gofeed"
	"golang.org/x/net/html/charset"
)

const (
	maxFeedDepth    = 256
	maxFeedItems    = 10_000
	maxFeedElements = 250_000
	maxAtomHTMLWork = 16 << 20

	errUnusableFeed = feedError("response is not a usable feed")
	errFeedTooLarge = feedError("feed is too large")
	errFeedTooDeep  = feedError("feed is nested too deeply")
	errTooManyItems = feedError("feed has too many items")
	errAtomMarkup   = feedError("Atom feed contains too much HTML markup")
)

func boundedFeed(ctx context.Context, body []byte) (*gofeed.Feed, error) {
	f, err := parseBoundedFeed(ctx, body)
	if errors.Is(err, errUnusableFeed) && !utf8.Valid(body) {
		f, err = parseBoundedFeed(ctx, bytes.ToValidUTF8(body, []byte("\uFFFD")))
	}
	return f, err
}

type feedReader struct {
	ctx context.Context
	io.Reader
}

func (r feedReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.Reader.Read(p)
}

func parseBoundedFeed(ctx context.Context, body []byte) (parsed *gofeed.Feed, resultErr error) {
	if len(body) > maxFeedBytes {
		return nil, errFeedTooLarge
	}
	if err := ctx.Err(); err != nil {
		return nil, feedTransportError(err, "feed request canceled")
	}
	prefix := bytes.TrimLeft(body, " \t\r\n\uFEFF")
	switch {
	case bytes.HasPrefix(prefix, []byte("{")):
		if hasJSONNUL(body) {
			return nil, errUnusableFeed
		}
		var feed struct{ Items jsonItemLimit }
		if bytes.Count(body, []byte("{"))+bytes.Count(body, []byte("[")) > maxFeedElements {
			return nil, errFeedTooLarge
		}
		if err := json.Unmarshal(body, &feed); err != nil {
			if errors.Is(err, errTooManyItems) {
				return nil, err
			}
			return nil, errUnusableFeed
		}
	case bytes.HasPrefix(prefix, []byte("<")):
		// Match the control-byte filter used by gofeed before tokenizing XML.
		if i := bytes.IndexFunc(body, invalidXMLControl); i >= 0 {
			clean := append(make([]byte, 0, len(body)), body[:i]...)
			for _, b := range body[i:] {
				if !invalidXMLControl(rune(b)) {
					clean = append(clean, b)
				}
			}
			body = clean
		}
		if err := checkFeedXML(feedReader{ctx, bytes.NewReader(body)}); err != nil {
			return nil, err
		}
	default:
		return nil, errUnusableFeed
	}
	parser := gofeed.NewParser()
	parser.RSSTranslator = &gofeed.DefaultRSSTranslator{DisableContentImageScan: true}
	defer func() {
		// Malformed JSON Feed arrays can make gofeed's translator panic.
		if recover() != nil {
			parsed, resultErr = nil, errUnusableFeed
		}
	}()
	f, err := parser.Parse(feedReader{ctx, bytes.NewReader(body)})
	if err := ctx.Err(); err != nil {
		return nil, feedTransportError(err, "feed request canceled")
	}
	if err != nil || f == nil || strings.TrimSpace(f.Title) == "" {
		return nil, errUnusableFeed
	}
	return f, nil
}

func invalidXMLControl(r rune) bool {
	return r < 0x20 && r != '\t' && r != '\n' && r != '\r'
}

func hasJSONNUL(body []byte) bool {
	escape := []byte(`\u0000`)
	for {
		i := bytes.Index(body, escape)
		if i == -1 {
			return false
		}
		start := i
		for start > 0 && body[start-1] == '\\' {
			start--
		}
		if (i-start)%2 == 0 {
			return true
		}
		body = body[i+len(escape):]
	}
}

type jsonItemLimit struct{}

func (*jsonItemLimit) UnmarshalJSON(data []byte) error {
	var items []struct{}
	if err := json.Unmarshal(data, &items); err != nil {
		return err
	}
	if len(items) > maxFeedItems {
		return errTooManyItems
	}
	return nil
}

func checkFeedXML(reader io.Reader) error {
	d := xml.NewDecoder(reader)
	d.Strict = false
	d.CharsetReader = charset.NewReaderLabel
	depth, items, elements := 0, 0, 0
	isAtom, baseSeen := false, false
	var rich atomHTMLLimit
	for {
		offset := d.InputOffset()
		token, err := d.Token()
		if err != nil {
			return feedTransportError(err, errUnusableFeed)
		}
		if rich.depth != 0 {
			if _, closing := token.(xml.EndElement); closing && depth == rich.depth {
				if err := rich.finish(offset); err != nil {
					return err
				}
			} else {
				if _, text := token.(xml.CharData); !text {
					rich.plain = false
				}
				rich.markup += htmlMarkers(token)
			}
		}
		switch tag := token.(type) {
		case xml.StartElement:
			depth++
			elements++
			if depth > maxFeedDepth {
				return errFeedTooDeep
			}
			if elements > maxFeedElements {
				return errFeedTooLarge
			}
			if isAtom || depth == 1 {
				for _, attr := range tag.Attr {
					baseSeen = baseSeen || attr.Name.Local == "base"
				}
			}
			name := strings.ToLower(tag.Name.Local)
			if name == "item" || name == "entry" {
				items++
				if items > maxFeedItems {
					return errTooManyItems
				}
			}
			if depth == 1 {
				isAtom = name == "feed"
			} else if isAtom && rich.depth == 0 {
				kind := atomRichText(tag)
				if kind != "" {
					rich.depth, rich.start, rich.markup = depth, d.InputOffset(), 0
					rich.plain = kind == "html" && !baseSeen
				}
			}
		case xml.EndElement:
			depth--
			if depth == 0 {
				return nil
			}
		}
	}
}

func atomRichText(tag xml.StartElement) string {
	for _, attr := range tag.Attr {
		if attr.Name.Local == "type" {
			value := strings.ToLower(attr.Value)
			if strings.Contains(value, "xhtml") {
				return "xhtml"
			}
			if value == "html" {
				return "html"
			}
		}
	}
	return ""
}

type atomHTMLLimit struct {
	plain  bool
	depth  int
	start  int64
	markup int64
	work   int64
}

func (limit *atomHTMLLimit) finish(end int64) error {
	limit.depth = 0
	// gofeed skips the HTML tree for escaped or CDATA text without an xml:base.
	if limit.plain {
		return nil
	}
	size := end - limit.start
	tags := limit.markup + 1
	// Atom's HTML tree builder can recreate formatting elements at each tag.
	limit.work += (size + 128*tags) * tags
	if size > maxDescriptionBytes || limit.work > maxAtomHTMLWork {
		return errAtomMarkup
	}
	return nil
}

func htmlMarkers(token xml.Token) int64 {
	switch t := token.(type) {
	case xml.StartElement:
		count := 1
		for _, attr := range t.Attr {
			count += strings.Count(attr.Value, "<") + strings.Count(attr.Value, "&")
		}
		return int64(count)
	case xml.EndElement:
		return 1
	case xml.CharData:
		return int64(bytes.Count(t, []byte("<")) + bytes.Count(t, []byte("&")))
	case xml.Comment:
		return int64(1 + bytes.Count(t, []byte("<")) + bytes.Count(t, []byte("&")))
	case xml.Directive:
		return int64(1 + bytes.Count(t, []byte("<")) + bytes.Count(t, []byte("&")))
	case xml.ProcInst:
		return int64(1 + bytes.Count(t.Inst, []byte("<")) + bytes.Count(t.Inst, []byte("&")))
	default:
		return 0
	}
}
