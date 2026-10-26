package proxy

import (
	"regexp"
	"strconv"
	"strings"
)

// Options are the image operations requested in the URL path.
type Options struct {
	Still  bool
	Resize bool
	Width  int
	Height int
}

var (
	digitsRe     = regexp.MustCompile(`^[0-9]+$`)
	whitespaceRe = regexp.MustCompile(`\s`)
	schemeFixRe  = regexp.MustCompile(`(?i)^(https?:/)([^/])`)
	schemeRe     = regexp.MustCompile(`(?i)^https?`)
)

// ParseRequest parses a raw request URI of the form
// /i/[still/][width/][height/]<url>, matching the original Perl service.
func ParseRequest(requestURI string) (opts Options, imageURL string, ok bool) {
	var rest string
	switch {
	case requestURI == "/i":
		return opts, "", false
	case strings.HasPrefix(requestURI, "/i/"):
		rest = requestURI[len("/i"):]
	default:
		return opts, "", false
	}

	if strings.HasPrefix(strings.TrimPrefix(rest, "/"), "favicon.ico") {
		return opts, "", false
	}

	var parts []string
	for _, p := range strings.Split(rest, "/") {
		if p != "" {
			parts = append(parts, p)
		}
	}

	if len(parts) > 0 && parts[0] == "still" {
		opts.Still = true
		parts = parts[1:]
	}

	var dims []int
	for range 2 {
		if len(parts) == 0 || !digitsRe.MatchString(parts[0]) {
			break
		}
		n, err := strconv.Atoi(parts[0])
		if err != nil {
			return Options{}, "", false
		}
		dims = append(dims, n)
		parts = parts[1:]
	}

	// width and height both 0 means no resize
	if !(len(dims) == 2 && dims[0] == 0 && dims[1] == 0) && len(dims) > 0 {
		opts.Resize = true
		opts.Width = dims[0]
		if len(dims) == 2 {
			opts.Height = dims[1]
		}
	}

	imageURL, ok = CleanURL(strings.Join(parts, "/"))
	if !ok {
		return Options{}, "", false
	}
	return opts, imageURL, true
}

// CleanURL normalizes the image URL taken from the request path.
func CleanURL(path string) (string, bool) {
	path = strings.TrimLeft(path, "/")
	// Perl treated "0" as false as well
	if path == "" || path == "0" {
		return "", false
	}

	path = strings.ReplaceAll(path, "&amp;", "&")
	path = whitespaceRe.ReplaceAllString(path, "%20")
	path = schemeFixRe.ReplaceAllString(path, "$1/$2")
	if !schemeRe.MatchString(path) {
		path = "http://" + path
	}
	return path, true
}
