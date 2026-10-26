package proxy

import "testing"

func TestSniffMIME(t *testing.T) {
	tests := []struct {
		data string
		want string
	}{
		{"\x89PNG\r\n\x1a\n", "image/png"},
		{"GIF89a\x01\x00", "image/gif"},
		{"RIFF\x00\x00\x00\x00WEBPVP8 ", "image/webp"},
		{"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00", "image/heic"},
		{"xPNG\x00\x00\x00\x00", "image/png"},
		{"\xff\xd8\xff\xe0", "image/jpeg"},
		{"BM\x00\x00\x00\x00", ""},
		{"<html>", ""},
		{"", ""},
		{"\xff", ""},
	}
	for _, tt := range tests {
		if got := SniffMIME([]byte(tt.data)); got != tt.want {
			t.Errorf("SniffMIME(%q) = %q, want %q", tt.data, got, tt.want)
		}
	}
}
