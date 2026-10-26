package proxy

import "bytes"

// SniffLen is how many leading bytes of a response are inspected.
const SniffLen = 1024

// SniffMIME returns the image MIME type of b based on magic bytes, or ""
// if b is not a supported image. Ported from File::Type::WebImages.
func SniffMIME(b []byte) string {
	switch {
	case bytes.HasPrefix(b, []byte("\x89PNG")):
		return "image/png"
	case bytes.HasPrefix(b, []byte("GIF8")):
		return "image/gif"
	case len(b) >= 12 && string(b[0:4]) == "RIFF" && string(b[8:12]) == "WEBP":
		return "image/webp"
	case len(b) >= 12 && string(b[8:12]) == "heic":
		return "image/heic"
	case len(b) > 1 && bytes.HasPrefix(b[1:], []byte("PNG")):
		return "image/png"
	case bytes.HasPrefix(b, []byte("\xff\xd8")):
		return "image/jpeg"
	}
	return ""
}
