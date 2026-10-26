# web-imageproxy: Go translator in front of imagor

Date: 2026-10-26

## Intent

Replace the Perl/Plack/ImageMagick service with a small Go translator that
speaks the existing `/i/...` API and delegates fetching and image processing to
a stock [imagor](https://github.com/cshum/imagor) container. Existing clients
must keep working without changes. A CDN sits in front and handles caching, so
the service itself should use as little memory and disk as possible and keep no
cache of its own.

## Goals

- Backwards-compatible URL API: same paths, same resize semantics, same
  `not found` 404s for non-images and upstream failures.
- Less code to own. libvips builds, format support, and future HEIC/AVIF
  support come from imagor's image.
- Low memory and disk use: no result storage, no temp files, bounded
  concurrency.

## Non-goals

- Caching inside the service (the CDN handles it).
- HEIC resizing for now. HEIC is still detected and served, just unresized
  (see below).
- BMP support.
- The imgur → noembed.com rerouting hack.
- The referer allowlist and its 301 redirect. It is always empty in
  `app.psgi`, so it is dead code today.
- `X-Image-Original-Length` header.
- The play-button overlay on `still` images. `still` is still accepted and
  returns the first frame only. `play_overlay.png` is deleted.

## Anti-goals

- Exposing imagor publicly or running it with `IMAGOR_UNSAFE`.
- Any behavior that makes the CDN cache errors or wrong content types under a
  URL that used to serve an image.
- Writing images to disk.

## Approaches considered

1. **Stock imagor container + small Go translator (chosen).** The translator is
   pure Go, stdlib only, no cgo. imagor's published image owns libvips. Cost:
   two containers to run.
2. imagor embedded as a Go library in one binary. One container, but we would
   build libvips ourselves again and depend on imagor's internal API.
3. Our own Go service on libvips (vipsgen). Exact compatibility and full
   control, but much more code, and HEIC/AVIF become our job.

Option 1 was chosen as the least code to own while still picking up imagor's
improvements for free.

## Behavior changes (accepted)

- **Animated GIF/WebP with a size** are now resized. Previously they were passed
  through untouched.
- **EXIF auto-rotate** is on. It was commented out in the Perl code.
- **BMP** is now treated as a non-image and returns a 404.
- **`still`** returns the first frame with no play overlay.
- Error bodies for edge cases (queue full, timeouts) may differ. See the
  response mapping below.

## Design

### Components

```
CDN ──> translator (:5007, Go) ──signed URL──> imagor (:8000, private)
                                                  │
                                                  └─ HTTP loader → origin images
```

### Request parsing (port of `Web::ImageProxy::call` + `clean_url`)

The translator handles everything under `/i/`.

1. A path starting with `/i/favicon.ico` returns a 404 `not found`.
2. Take the **raw** request URI (`r.RequestURI`, including the query string,
   undecoded) and strip the `/i` prefix. This matches Perl's use of
   `REQUEST_URI`.
3. Split on `/` and drop empty segments. Then, in order:
   - a leading `still` segment sets `still`
   - a leading all-digits segment sets `width`
   - another leading all-digits segment sets `height`
   - if width and height are both 0, both are cleared
4. Join the remaining segments with `/` and apply `clean_url`:
   - strip leading `/`; an empty result returns a 404
   - replace `&amp;` with `&`
   - replace whitespace with `%20`
   - repair a collapsed scheme (`http:/x` → `http://x`), case-insensitively
   - prefix `http://` if the URL does not start with `http`

   Note: because empty segments are dropped, `https://` becomes `https:/` after
   the join, which is why the scheme repair step exists. Port this exactly.

### Mapping to imagor

The image URL is escaped with `url.QueryEscape` semantics, equivalent to
`encodeURIComponent`, per imagor's docs for URLs containing `?`. imagor decodes
it exactly once, so the original URL string is what gets fetched.

| Parsed options | imagor path (before signing) |
|---|---|
| none | `filters:raw()/<esc url>` |
| width W, height H (either may be absent; absent → 0) | `fit-in/WxH/<esc url>` |
| `still` (+ optional size) | `[fit-in/WxH/]filters:max_frames(1)/<esc url>` |

- `fit-in` keeps aspect ratio and does not upscale unless `upscale()` is used,
  matching ImageMagick's `WxH>` (the builder should confirm no-upscale on a
  small image).
- The output format stays the same as the source. Do **not** enable
  `IMAGOR_AUTO_WEBP` / `IMAGOR_AUTO_AVIF`: the CDN cache key does not vary on
  `Accept`.
- `still` with no size still goes through processing (`max_frames(1)`), not
  `raw()`. On a still image it has no visible effect.

### Signing

The translator and imagor share `IMAGOR_SECRET`, using imagor's default
HMAC-SHA1. Sign the path above, base64url-encode the signature with padding
kept (as in imagor's docs), and request `http://imagor:8000/<sig>/<path>`. The
imagor URL is configurable with the `IMAGOR_URL` env var.

### Response mapping

The translator proxies imagor's response and streams the body. It never
buffers more than the sniff window described below.

- **imagor 200:**
  - Copy the body and `Content-Length`.
  - **Content-Type:** set from magic-byte sniffing of the first bytes, matching
    the old `get_mime_type` behavior: PNG, GIF, WebP (`RIFF....WEBP`), HEIC
    (ftyp brand `heic` at offset 8), PNG at offset 1, JPEG `FFD8`. BMP is
    removed. If the sniff fails, return a 404 `not found` instead. This matters
    most for `raw()`, which imagor does not check, and is what keeps non-images
    out of the CDN.
  - **ETag:** upstream's if present, otherwise `sha1_hex(url)` over the
    cleaned URL. To get upstream's, imagor is configured with
    `HTTP_LOADER_OVERRIDE_RESPONSE_HEADERS=ETag,Last-Modified`.
  - **Last-Modified:** upstream's if present, otherwise the current time in
    HTTP-date format.
  - **Cache-Control:** pass imagor's through unchanged (default
    `max-age` 7d, `stale-while-revalidate` 1d). nginx in front can
    overwrite it if needed.
- **Any non-200 from imagor** (upstream 404, non-image, too large, timeout):
  return 404, `Content-Type: text/plain`, body `not found`. This matches Perl,
  where every failure ends in that 404. Log imagor's status and the URL to
  stderr, like the old `print STDERR`.
- **Exception:** imagor 429 (queue full) → 503 `error processing request`, so
  the CDN does not cache a 404 for a valid image.
- If imagor itself is unreachable, return 503.

### imagor configuration (memory/disk-lean)

Use the stock `shumc/imagor:<pinned version>` image. No custom image is needed.

```
IMAGOR_SECRET=<shared>
HTTP_LOADER_MAX_ALLOWED_SIZE=10485760
HTTP_LOADER_BLOCK_LOOPBACK_NETWORKS=1
HTTP_LOADER_BLOCK_PRIVATE_NETWORKS=1
HTTP_LOADER_BLOCK_LINK_LOCAL_NETWORKS=1
HTTP_LOADER_OVERRIDE_RESPONSE_HEADERS=ETag,Last-Modified
IMAGOR_REQUEST_TIMEOUT=60s            # old service used 60s
IMAGOR_RESPONSE_RAW_ON_ERROR=1        # serve original if processing fails (old behavior; also covers HEIC)
IMAGOR_PROCESS_CONCURRENCY=<nCPU>
IMAGOR_PROCESS_QUEUE_SIZE=<small, e.g. 50>
VIPS_CONCURRENCY=1
VIPS_MAX_RESOLUTION=<cap, e.g. 50000000 pixels>  # bounds decode memory
# no result storage, no VIPS_CACHE_SIZE
```

Upstream fetches send the old Firefox User-Agent and no Referer. The builder
needs to find imagor's setting for the default User-Agent. It is not in the
docs pages read so far; likely `HTTP_LOADER_DEFAULT_USER_AGENT`.

HEIC: `IMAGOR_RESPONSE_RAW_ON_ERROR` means a resize request for HEIC either
works, if the image's libvips has libheif, or falls back to the original. Both
are acceptable now.

### Layout

```
cmd/imageproxy/main.go     # flags/env, http server on :5007
internal/proxy/            # parse.go, imagor.go (path+sign), sniff.go, handler.go + _test.go
Dockerfile                 # multi-stage: golang build → distroless/static
docker-compose.yml         # example wiring: translator + pinned shumc/imagor + env
```

Delete `app.psgi`, `lib/`, `cpanfile`, and `cpanfile.snapshot`, and
`play_overlay.png`, and replace the Perl Dockerfile.

### CI / deploy

`.github/workflows/deploy.yml` builds and pushes the translator image under the
current name (`ghcr.io/<repo>`), with the workflow otherwise unchanged. The
deploy target adds the pinned `shumc/imagor` container next to it. That wiring
is outside this repo; `docker-compose.yml` documents it.

## Testing

- Unit tests (table-driven) for parsing and `clean_url`. Use cases taken from
  the Perl code, including `https:/` repair, `&amp;`, spaces, query strings,
  `0/0`, `still` alone, and width only.
- Unit tests for imagor path building and signing, checked against the signing
  example in imagor's docs.
- Unit tests for the sniffer, one per format plus BMP → none.
- Integration test (docker compose, run locally or in CI): real imagor plus an
  `httptest` origin serving fixtures (PNG, JPEG, animated GIF, WebP, a text
  file, a 404, and a file over 10 MB). Assert statuses, Content-Type, ETag,
  dimensions after resize, no upscaling, `still` → a single-frame GIF, and EXIF
  rotation, and that imagor's Cache-Control is passed through.

## Builder's calls (decided without asking)

- Map all imagor failures to 404 `not found`, except 429 and imagor being
  unreachable, which return 503.
- Block private, loopback, and link-local networks for upstream fetches. This
  closes an SSRF hole the old service had.
- Pin the imagor image version and keep auto-WebP off.
- Use a distroless static base image for the translator.
