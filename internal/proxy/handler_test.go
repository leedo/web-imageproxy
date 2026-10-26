package proxy

import (
	"bytes"
	"crypto/sha1"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"
)

const testSecret = "secret"

var fixedNow = time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)

// newTestHandler returns a Handler backed by a fake imagor that serves
// responses with fn and records the raw request URI it received.
func newTestHandler(t *testing.T, fn http.HandlerFunc) (*Handler, *string) {
	t.Helper()
	var got string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r.RequestURI
		fn(w, r)
	}))
	t.Cleanup(srv.Close)
	return &Handler{
		ImagorURL: srv.URL,
		Secret:    testSecret,
		Client:    srv.Client(),
		Now:       func() time.Time { return fixedNow },
		Log:       log.New(io.Discard, "", 0),
	}, &got
}

func serve(h http.Handler, path string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
	return rec
}

func assertNotFound(t *testing.T, rec *httptest.ResponseRecorder) {
	t.Helper()
	if rec.Code != 404 || rec.Body.String() != "not found" || rec.Header().Get("Content-Type") != "text/plain" {
		t.Errorf("got %d %q (%s), want 404 not found", rec.Code, rec.Body.String(), rec.Header().Get("Content-Type"))
	}
}

func pngBytes(n int) []byte {
	b := make([]byte, n)
	copy(b, "\x89PNG\r\n\x1a\n")
	for i := 8; i < n; i++ {
		b[i] = byte(i)
	}
	return b
}

func TestHandlerSignsPath(t *testing.T) {
	h, got := newTestHandler(t, func(w http.ResponseWriter, r *http.Request) {
		w.Write(pngBytes(10))
	})
	serve(h, "/i/200/x.com/a.png")
	p := ImagorPath(Options{Resize: true, Width: 200}, "http://x.com/a.png")
	if want := "/" + Sign(testSecret, p) + "/" + p; *got != want {
		t.Errorf("imagor saw %q, want %q", *got, want)
	}
}

func TestHandlerPassesImage(t *testing.T) {
	body := pngBytes(2000)
	h, _ := newTestHandler(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("ETag", `"abc"`)
		w.Header().Set("Last-Modified", "Mon, 02 Jan 2006 15:04:05 GMT")
		w.Header().Set("Cache-Control", "max-age=604800")
		w.Header().Set("X-Foo", "1")
		w.Header().Set("Content-Length", strconv.Itoa(len(body)))
		w.Write(body)
	})
	rec := serve(h, "/i/x.com/a.png")
	if rec.Code != 200 {
		t.Fatalf("status = %d", rec.Code)
	}
	if !bytes.Equal(rec.Body.Bytes(), body) {
		t.Error("body differs")
	}
	for k, want := range map[string]string{
		"Content-Type":   "image/png",
		"ETag":           `"abc"`,
		"Last-Modified":  "Mon, 02 Jan 2006 15:04:05 GMT",
		"Cache-Control":  "max-age=604800",
		"Content-Length": "2000",
		"X-Foo":          "",
	} {
		if got := rec.Header().Get(k); got != want {
			t.Errorf("%s = %q, want %q", k, got, want)
		}
	}
}

func TestHandlerSmallImage(t *testing.T) {
	body := []byte("GIF89a\x01\x02\x03\x04")
	h, _ := newTestHandler(t, func(w http.ResponseWriter, r *http.Request) {
		w.Write(body)
	})
	rec := serve(h, "/i/x.com/a.gif")
	if rec.Code != 200 || !bytes.Equal(rec.Body.Bytes(), body) || rec.Header().Get("Content-Type") != "image/gif" {
		t.Errorf("got %d %q %s", rec.Code, rec.Body.Bytes(), rec.Header().Get("Content-Type"))
	}
}

func TestHandlerDefaultHeaders(t *testing.T) {
	h, _ := newTestHandler(t, func(w http.ResponseWriter, r *http.Request) {
		w.Write(pngBytes(10))
	})
	rec := serve(h, "/i/x.com/a.png")
	if want := fmt.Sprintf("%x", sha1.Sum([]byte("http://x.com/a.png"))); rec.Header().Get("ETag") != want {
		t.Errorf("ETag = %q, want %q", rec.Header().Get("ETag"), want)
	}
	if want := fixedNow.Format(http.TimeFormat); rec.Header().Get("Last-Modified") != want {
		t.Errorf("Last-Modified = %q, want %q", rec.Header().Get("Last-Modified"), want)
	}
}

func TestHandlerNonImage404(t *testing.T) {
	h, _ := newTestHandler(t, func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("<html>"))
	})
	assertNotFound(t, serve(h, "/i/x.com/a.png"))
}

func TestHandlerImagorError404(t *testing.T) {
	for _, code := range []int{400, 404, 500} {
		t.Run(strconv.Itoa(code), func(t *testing.T) {
			h, _ := newTestHandler(t, func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(code)
				w.Write(pngBytes(10))
			})
			assertNotFound(t, serve(h, "/i/x.com/a.png"))
		})
	}
}

func TestHandler429Is503(t *testing.T) {
	h, _ := newTestHandler(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(429)
	})
	rec := serve(h, "/i/x.com/a.png")
	if rec.Code != 503 || rec.Body.String() != "error processing request" {
		t.Errorf("got %d %q", rec.Code, rec.Body.String())
	}
}

func TestHandlerUnreachable503(t *testing.T) {
	h, _ := newTestHandler(t, func(w http.ResponseWriter, r *http.Request) {})
	srv := httptest.NewServer(http.NotFoundHandler())
	h.ImagorURL = srv.URL
	srv.Close()
	rec := serve(h, "/i/x.com/a.png")
	if rec.Code != 503 || rec.Body.String() != "error processing request" {
		t.Errorf("got %d %q", rec.Code, rec.Body.String())
	}
}

func TestHandlerBadPath404(t *testing.T) {
	h, _ := newTestHandler(t, func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("imagor contacted for %s", r.RequestURI)
	})
	for _, p := range []string{"/i/", "/i/favicon.ico"} {
		assertNotFound(t, serve(h, p))
	}
}
