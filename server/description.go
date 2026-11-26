package main

import (
	"net/url"
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/net/html"
	"golang.org/x/net/html/atom"
)

const maxDescriptionBytes = 256 << 10
const maxDescriptionChars = 20_000

type descriptionText struct {
	text      strings.Builder
	remaining int
	space     rune
}

func (d *descriptionText) write(s string) {
	for _, r := range s {
		if d.remaining == 0 {
			return
		}
		if r == '\n' {
			d.space = '\n'
			continue
		}
		if unicode.IsSpace(r) {
			if d.space == 0 {
				d.space = ' '
			}
			continue
		}
		if d.space != 0 && d.text.Len() != 0 {
			d.text.WriteRune(d.space)
			d.remaining--
			if d.remaining == 0 {
				return
			}
		}
		d.space = 0
		d.text.WriteRune(r)
		d.remaining--
	}
}

func plainText(source string, base *url.URL) string {
	if len(source) > maxDescriptionBytes {
		n := maxDescriptionBytes
		for n > 0 && !utf8.RuneStart(source[n]) {
			n--
		}
		source = source[:n]
	}
	z := html.NewTokenizer(strings.NewReader(source))
	out := descriptionText{remaining: maxDescriptionChars}
	current := &out
	var label descriptionText
	var href string
	closeLink := func() {
		if current != &label {
			return
		}
		text := label.text.String()
		if link := resolveLink(base, href); link != nil {
			if text == "" || text == href {
				text = *link
			} else if text != *link {
				out.write(text)
				text = " (" + *link + ")"
			}
		}
		out.write(text)
		current = &out
	}
	var hidden []atom.Atom
	for current.remaining > 0 {
		kind := z.Next()
		if kind == html.ErrorToken {
			break
		}
		switch kind {
		case html.TextToken:
			if len(hidden) == 0 {
				current.write(string(z.Text()))
			}
		case html.StartTagToken, html.SelfClosingTagToken, html.EndTagToken:
			name, hasAttr := z.TagName()
			tag := atom.Lookup(name)
			switch tag {
			case atom.Script, atom.Style, atom.Template:
				if kind != html.EndTagToken {
					hidden = append(hidden, tag)
				} else if kind == html.EndTagToken && len(hidden) > 0 && hidden[len(hidden)-1] == tag {
					hidden = hidden[:len(hidden)-1]
				}
			default:
				if len(hidden) != 0 {
					continue
				}
				switch tag {
				case atom.Br, atom.P, atom.Div, atom.Li, atom.H1, atom.H2, atom.H3, atom.H4, atom.H5, atom.H6, atom.Blockquote:
					current.space = '\n'
				case atom.A:
					closeLink()
					if kind == html.EndTagToken {
						continue
					}
					href = ""
					for hasAttr {
						var key, value []byte
						key, value, hasAttr = z.TagAttr()
						if string(key) == "href" {
							href = string(value)
							break
						}
					}
					label = descriptionText{remaining: out.remaining}
					current = &label
					if kind == html.SelfClosingTagToken {
						closeLink()
					}
				}
			}
		}
	}
	closeLink()
	return out.text.String()
}
