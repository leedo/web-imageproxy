package proxy

import (
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"fmt"
	"net/url"
	"strings"
)

// ImagorPath builds the unsigned imagor path (no leading slash) for the
// requested options.
func ImagorPath(opts Options, imageURL string) string {
	var b strings.Builder
	if opts.Resize {
		fmt.Fprintf(&b, "fit-in/%dx%d/", opts.Width, opts.Height)
	}
	switch {
	case opts.Still:
		b.WriteString("filters:max_frames(1)/")
	case !opts.Resize:
		b.WriteString("filters:raw()/")
	}
	b.WriteString(url.QueryEscape(imageURL))
	return b.String()
}

// Sign returns imagor's HMAC-SHA1 signature for path.
func Sign(secret, path string) string {
	mac := hmac.New(sha1.New, []byte(secret))
	mac.Write([]byte(path))
	return base64.URLEncoding.EncodeToString(mac.Sum(nil))
}

// SignedURL returns the full signed imagor URL for the request.
func SignedURL(base, secret string, opts Options, imageURL string) string {
	p := ImagorPath(opts, imageURL)
	return strings.TrimRight(base, "/") + "/" + Sign(secret, p) + "/" + p
}
