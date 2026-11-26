package main

import (
	"context"
	"encoding/xml"
	"errors"
	"io"
	"strings"
)

type opmlDocument struct {
	XMLName xml.Name `xml:"opml"`
	Version string   `xml:"version,attr,omitempty"`
	Title   string   `xml:"head>title,omitempty"`
	Body    *struct {
		Outlines []outline `xml:"outline"`
	} `xml:"body"`
}

type outline struct {
	Text     string    `xml:"text,attr,omitempty"`
	Type     string    `xml:"type,attr,omitempty"`
	XMLURL   string    `xml:"xmlUrl,attr,omitempty"`
	HTMLURL  string    `xml:"htmlUrl,attr,omitempty"`
	Children []outline `xml:"outline"`
}

type opmlFailure struct {
	FeedURL string `json:"feed_url"`
	Error   string `json:"error"`
}

type opmlResult struct {
	Added    int           `json:"added"`
	Existing int           `json:"existing"`
	Failed   []opmlFailure `json:"failed"`
}

var errInvalidOPML = errors.New("invalid OPML document")

func parseOPML(reader io.Reader) ([]string, error) {
	decoder := xml.NewDecoder(reader)
	var doc opmlDocument
	if err := decoder.Decode(&doc); err != nil || doc.Body == nil {
		return nil, errInvalidOPML
	}
	for {
		token, err := decoder.Token()
		if err == io.EOF {
			break
		}
		switch v := token.(type) {
		case xml.Comment, xml.ProcInst:
			continue
		case xml.CharData:
			if strings.TrimSpace(string(v)) == "" {
				continue
			}
		}
		return nil, errInvalidOPML
	}
	urls := []string{}
	var walk func([]outline)
	walk = func(items []outline) {
		for _, item := range items {
			if item.XMLURL != "" {
				urls = append(urls, item.XMLURL)
			}
			walk(item.Children)
		}
	}
	walk(doc.Body.Outlines)
	return urls, nil
}

func (r *refresher) importOPML(ctx context.Context, urls []string) (opmlResult, error) {
	result := opmlResult{Failed: []opmlFailure{}}
	for _, address := range urls {
		_, added, err := r.subscribe(ctx, address)
		var issue feedError
		switch {
		case errors.As(err, &issue):
			result.Failed = append(result.Failed, opmlFailure{address, issue.Error()})
		case err != nil:
			return result, err
		case added:
			result.Added++
		default:
			result.Existing++
		}
	}
	return result, nil
}

func exportOPML(podcasts []podcast) ([]byte, error) {
	doc := opmlDocument{Version: "2.0", Title: "EasyPodcast subscriptions"}
	doc.Body = &struct {
		Outlines []outline `xml:"outline"`
	}{}
	for _, p := range podcasts {
		item := outline{Text: p.Title, XMLURL: p.FeedURL, Type: "rss"}
		if p.Link != nil {
			item.HTMLURL = *p.Link
		}
		doc.Body.Outlines = append(doc.Body.Outlines, item)
	}
	data, err := xml.MarshalIndent(doc, "", "  ")
	if err != nil {
		return nil, err
	}
	return append([]byte(xml.Header), data...), nil
}
