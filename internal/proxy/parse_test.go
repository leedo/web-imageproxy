package proxy

import "testing"

func TestParseRequest(t *testing.T) {
	tests := []struct {
		name     string
		uri      string
		wantOpts Options
		wantURL  string
		wantOK   bool
	}{
		{"plain http", "/i/http://x.com/a.png", Options{}, "http://x.com/a.png", true},
		{"https scheme repair", "/i/https://x.com/a.png", Options{}, "https://x.com/a.png", true},
		{"no scheme", "/i/x.com/a.png", Options{}, "http://x.com/a.png", true},
		{"uppercase scheme", "/i/HTTPS:/x.com/a.png", Options{}, "HTTPS://x.com/a.png", true},
		{"width", "/i/200/x.com/a.png", Options{Resize: true, Width: 200}, "http://x.com/a.png", true},
		{"width height", "/i/200/100/x.com/a.png", Options{Resize: true, Width: 200, Height: 100}, "http://x.com/a.png", true},
		{"zero zero cleared", "/i/0/0/x.com/a.png", Options{}, "http://x.com/a.png", true},
		{"zero width", "/i/0/x.com/a.png", Options{Resize: true}, "http://x.com/a.png", true},
		{"still", "/i/still/x.com/a.gif", Options{Still: true}, "http://x.com/a.gif", true},
		{"still with size", "/i/still/50/50/x.com/a.gif", Options{Still: true, Resize: true, Width: 50, Height: 50}, "http://x.com/a.gif", true},
		{"still after width", "/i/200/still/x.com/a.png", Options{Resize: true, Width: 200}, "http://still/x.com/a.png", true},
		{"query with slashes", "/i/https://x.com/a.png?u=http://y.com//z&amp;b=1", Options{}, "https://x.com/a.png?u=http:/y.com/z&b=1", true},
		{"spaces", "/i/x.com/a b.png", Options{}, "http://x.com/a%20b.png", true},
		{"overflow width", "/i/99999999999999999999/x.com/a.png", Options{}, "", false},
		{"bare mount", "/i", Options{}, "", false},
		{"mount slash", "/i/", Options{}, "", false},
		{"size only", "/i/200/100/", Options{}, "", false},
		{"favicon", "/i/favicon.ico", Options{}, "", false},
		{"other prefix", "/other/x.com/a.png", Options{}, "", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			opts, u, ok := ParseRequest(tt.uri)
			if ok != tt.wantOK {
				t.Fatalf("ok = %v, want %v", ok, tt.wantOK)
			}
			if !ok {
				return
			}
			if opts != tt.wantOpts {
				t.Errorf("opts = %+v, want %+v", opts, tt.wantOpts)
			}
			if u != tt.wantURL {
				t.Errorf("url = %q, want %q", u, tt.wantURL)
			}
		})
	}
}

func TestCleanURL(t *testing.T) {
	if _, ok := CleanURL(""); ok {
		t.Error(`CleanURL("") ok`)
	}
	if _, ok := CleanURL("/"); ok {
		t.Error(`CleanURL("/") ok`)
	}
	if u, ok := CleanURL("//x.com/a"); !ok || u != "http://x.com/a" {
		t.Errorf(`CleanURL("//x.com/a") = %q, %v`, u, ok)
	}
}
