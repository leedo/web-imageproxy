//go:build e2e

package proxy

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/gif"
	"image/jpeg"
	"image/png"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"testing"
)

// Run with: docker compose -f docker-compose.e2e.yml up -d && go test -tags e2e ./internal/proxy/

func solid(w, h int) *image.RGBA {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, color.RGBA{uint8(x), uint8(y), 128, 255})
		}
	}
	return img
}

func encodePNG(t *testing.T, w, h int) []byte {
	var b bytes.Buffer
	if err := png.Encode(&b, solid(w, h)); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func encodeAnimGIF(t *testing.T) []byte {
	var g gif.GIF
	for i := 0; i < 3; i++ {
		p := image.NewPaletted(image.Rect(0, 0, 100, 100), color.Palette{color.Black, color.White})
		for x := 0; x < 100; x++ {
			p.SetColorIndex(x, i*10, 1)
		}
		g.Image = append(g.Image, p)
		g.Delay = append(g.Delay, 10)
	}
	var b bytes.Buffer
	if err := gif.EncodeAll(&b, &g); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

// withOrientation inserts a minimal EXIF APP1 segment carrying orientation o
// right after the JPEG SOI marker.
func withOrientation(jpg []byte, o uint16) []byte {
	var tiff bytes.Buffer
	tiff.WriteString("MM\x00\x2A\x00\x00\x00\x08")
	tiff.Write([]byte{0x00, 0x01})                         // one IFD entry
	tiff.Write([]byte{0x01, 0x12, 0x00, 0x03})             // Orientation, SHORT
	tiff.Write([]byte{0x00, 0x00, 0x00, 0x01})             // count 1
	binary.Write(&tiff, binary.BigEndian, o)               // value
	tiff.Write([]byte{0x00, 0x00, 0x00, 0x00, 0x00, 0x00}) // padding + next IFD
	payload := append([]byte("Exif\x00\x00"), tiff.Bytes()...)

	var b bytes.Buffer
	b.Write(jpg[:2])
	b.Write([]byte{0xFF, 0xE1})
	binary.Write(&b, binary.BigEndian, uint16(2+len(payload)))
	b.Write(payload)
	b.Write(jpg[2:])
	return b.Bytes()
}

func encodeRotatedJPEG(t *testing.T) []byte {
	var b bytes.Buffer
	if err := jpeg.Encode(&b, solid(200, 100), nil); err != nil {
		t.Fatal(err)
	}
	return withOrientation(b.Bytes(), 6)
}

type e2eEnv struct {
	handler http.Handler
	origin  string

	mu        sync.Mutex
	userAgent string
}

func setupE2E(t *testing.T) *e2eEnv {
	t.Helper()
	env := &e2eEnv{}
	files := map[string][]byte{
		"/big.png":   encodePNG(t, 800, 600),
		"/small.png": encodePNG(t, 50, 40),
		"/anim.gif":  encodeAnimGIF(t),
		"/rot.jpg":   encodeRotatedJPEG(t),
		"/page.html": []byte("<html><body>hello</body></html>"),
		"/huge.png":  append([]byte("\x89PNG\r\n\x1a\n"), make([]byte, 11<<20)...),
	}
	ln, err := net.Listen("tcp", "0.0.0.0:0")
	if err != nil {
		t.Fatal(err)
	}
	origin := &httptest.Server{
		Listener: ln,
		Config: &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/big.png" {
				env.mu.Lock()
				env.userAgent = r.Header.Get("User-Agent")
				env.mu.Unlock()
				w.Header().Set("ETag", `"origin-etag"`)
			}
			body, ok := files[r.URL.Path]
			if !ok {
				http.NotFound(w, r)
				return
			}
			w.Header().Set("Content-Length", strconv.Itoa(len(body)))
			w.Write(body)
		})},
	}
	origin.Start()
	t.Cleanup(origin.Close)

	env.origin = "http://host.docker.internal:" + strconv.Itoa(ln.Addr().(*net.TCPAddr).Port)
	env.handler = &Handler{ImagorURL: "http://localhost:8000", Secret: "e2e"}
	return env
}

func (e *e2eEnv) get(t *testing.T, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	e.handler.ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
	return rec
}

func decodeSize(t *testing.T, rec *httptest.ResponseRecorder) (int, int) {
	t.Helper()
	cfg, _, err := image.DecodeConfig(bytes.NewReader(rec.Body.Bytes()))
	if err != nil {
		t.Fatalf("decode: %v (status %d)", err, rec.Code)
	}
	return cfg.Width, cfg.Height
}

func TestE2E(t *testing.T) {
	env := setupE2E(t)

	rec := env.get(t, "/i/"+env.origin+"/big.png")
	if rec.Code != 200 {
		t.Fatalf("raw big.png: status %d; imagor can't reach origin (private-network block?)", rec.Code)
	}

	t.Run("raw passthrough", func(t *testing.T) {
		if ct := rec.Header().Get("Content-Type"); ct != "image/png" {
			t.Errorf("Content-Type = %q", ct)
		}
		if w, h := decodeSize(t, rec); w != 800 || h != 600 {
			t.Errorf("size = %dx%d, want 800x600", w, h)
		}
		if et := rec.Header().Get("ETag"); et != `"origin-etag"` {
			t.Errorf("ETag = %q, want origin's", et)
		}
		env.mu.Lock()
		defer env.mu.Unlock()
		if env.userAgent != UserAgent {
			t.Errorf("origin saw User-Agent %q", env.userAgent)
		}
	})

	sizes := []struct {
		path string
		w, h int
	}{
		{"/i/200/" + env.origin + "/big.png", 200, 150},
		{"/i/200/100/" + env.origin + "/big.png", 133, 100},
		{"/i/200/" + env.origin + "/small.png", 50, 40},
		{"/i/50/" + env.origin + "/rot.jpg", 50, 100},
	}
	for _, s := range sizes {
		t.Run(s.path, func(t *testing.T) {
			rec := env.get(t, s.path)
			if w, h := decodeSize(t, rec); w != s.w || h != s.h {
				t.Errorf("size = %dx%d, want %dx%d", w, h, s.w, s.h)
			}
		})
	}

	t.Run("resize sends cache-control", func(t *testing.T) {
		rec := env.get(t, "/i/200/"+env.origin+"/big.png")
		if rec.Header().Get("Cache-Control") == "" {
			t.Error("no Cache-Control")
		}
	})

	t.Run("animated gif resized", func(t *testing.T) {
		rec := env.get(t, "/i/50/"+env.origin+"/anim.gif")
		g, err := gif.DecodeAll(bytes.NewReader(rec.Body.Bytes()))
		if err != nil {
			t.Fatalf("decode: %v (status %d)", err, rec.Code)
		}
		if len(g.Image) != 3 || g.Config.Width != 50 || g.Config.Height != 50 {
			t.Errorf("got %d frames %dx%d, want 3 frames 50x50", len(g.Image), g.Config.Width, g.Config.Height)
		}
	})

	t.Run("still gif single frame", func(t *testing.T) {
		rec := env.get(t, "/i/still/"+env.origin+"/anim.gif")
		g, err := gif.DecodeAll(bytes.NewReader(rec.Body.Bytes()))
		if err != nil {
			t.Fatalf("decode: %v (status %d)", err, rec.Code)
		}
		if len(g.Image) != 1 {
			t.Errorf("got %d frames, want 1", len(g.Image))
		}
	})

	for _, p := range []string{"/page.html", "/missing.png", "/huge.png"} {
		for _, prefix := range []string{"/i/", "/i/200/"} {
			t.Run(prefix+p, func(t *testing.T) {
				assertNotFound(t, env.get(t, prefix+env.origin+p))
			})
		}
	}
}
