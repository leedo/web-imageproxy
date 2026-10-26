package proxy

import (
	"bufio"
	"crypto/sha1"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"
)

// UserAgent is sent to imagor, which forwards it to the origin
// (HTTP_LOADER_FORWARD_HEADERS=User-Agent).
const UserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:109.0) Gecko/20100101 Firefox/112.0"

// Handler serves the /i/ API by proxying signed requests to imagor.
type Handler struct {
	ImagorURL string
	Secret    string
	Client    *http.Client
	Now       func() time.Time
	Log       *log.Logger
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	opts, imageURL, ok := ParseRequest(r.RequestURI)
	if !ok {
		notFound(w)
		return
	}

	req, err := http.NewRequestWithContext(r.Context(), "GET", SignedURL(h.ImagorURL, h.Secret, opts, imageURL), nil)
	if err != nil {
		notFound(w)
		return
	}
	req.Header.Set("User-Agent", UserAgent)
	res, err := h.client().Do(req)
	if err != nil {
		h.logger().Printf("imagor request failed for %s: %v", imageURL, err)
		unavailable(w)
		return
	}
	defer res.Body.Close()

	switch res.StatusCode {
	case http.StatusOK:
	case http.StatusTooManyRequests, http.StatusServiceUnavailable:
		h.logger().Printf("got %d for %s", res.StatusCode, imageURL)
		unavailable(w)
		return
	default:
		h.logger().Printf("got %d for %s", res.StatusCode, imageURL)
		notFound(w)
		return
	}

	body := bufio.NewReaderSize(res.Body, SniffLen)
	head, err := body.Peek(SniffLen)
	if err != nil && !errors.Is(err, io.EOF) {
		h.logger().Printf("reading imagor response for %s: %v", imageURL, err)
		unavailable(w)
		return
	}
	mime := SniffMIME(head)
	if mime == "" {
		h.logger().Printf("not an image: %s", imageURL)
		notFound(w)
		return
	}

	hdr := w.Header()
	hdr.Set("Content-Type", mime)
	for _, k := range []string{"Content-Length", "Cache-Control"} {
		if v := res.Header.Get(k); v != "" {
			hdr.Set(k, v)
		}
	}
	etag := res.Header.Get("ETag")
	if etag == "" {
		etag = fmt.Sprintf("%x", sha1.Sum([]byte(imageURL)))
	}
	hdr.Set("ETag", etag)
	modified := res.Header.Get("Last-Modified")
	if modified == "" {
		modified = h.now().UTC().Format(http.TimeFormat)
	}
	hdr.Set("Last-Modified", modified)

	w.WriteHeader(http.StatusOK)
	io.Copy(w, body)
}

func (h *Handler) client() *http.Client {
	if h.Client != nil {
		return h.Client
	}
	return http.DefaultClient
}

func (h *Handler) now() time.Time {
	if h.Now != nil {
		return h.Now()
	}
	return time.Now()
}

func (h *Handler) logger() *log.Logger {
	if h.Log != nil {
		return h.Log
	}
	return log.Default()
}

func notFound(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusNotFound)
	io.WriteString(w, "not found")
}

func unavailable(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusServiceUnavailable)
	io.WriteString(w, "error processing request")
}
