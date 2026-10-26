package proxy

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"net/url"
	"strings"
	"testing"
)

func TestImagorPath(t *testing.T) {
	u := "https://x.com/a.png?v=1&b=2"
	e := url.QueryEscape(u)
	if strings.ContainsAny(e, "?&/") {
		t.Fatalf("escaped url %q contains ?, & or /", e)
	}
	tests := []struct {
		opts Options
		want string
	}{
		{Options{}, "filters:raw()/" + e},
		{Options{Resize: true, Width: 200}, "fit-in/200x0/" + e},
		{Options{Resize: true, Height: 100}, "fit-in/0x100/" + e},
		{Options{Resize: true, Width: 200, Height: 100}, "fit-in/200x100/" + e},
		{Options{Still: true}, "filters:max_frames(1)/" + e},
		{Options{Still: true, Resize: true, Width: 50, Height: 50}, "fit-in/50x50/filters:max_frames(1)/" + e},
	}
	for _, tt := range tests {
		if got := ImagorPath(tt.opts, u); got != tt.want {
			t.Errorf("ImagorPath(%+v) = %q, want %q", tt.opts, got, tt.want)
		}
	}
}

func TestSign(t *testing.T) {
	mac := hmac.New(sha1.New, []byte("s"))
	mac.Write([]byte("fit-in/200x0/abc"))
	want := base64.URLEncoding.EncodeToString(mac.Sum(nil))
	got := Sign("s", "fit-in/200x0/abc")
	if got != want {
		t.Errorf("Sign = %q, want %q", got, want)
	}
	if !strings.HasSuffix(got, "=") {
		t.Errorf("Sign = %q, want padded base64", got)
	}
}

func TestSignedURL(t *testing.T) {
	opts := Options{Resize: true, Width: 200}
	p := ImagorPath(opts, "http://x.com/a.png")
	want := "http://imagor:8000/" + Sign("s", p) + "/" + p
	for _, base := range []string{"http://imagor:8000", "http://imagor:8000/"} {
		if got := SignedURL(base, "s", opts, "http://x.com/a.png"); got != want {
			t.Errorf("SignedURL(%q) = %q, want %q", base, got, want)
		}
	}
}
