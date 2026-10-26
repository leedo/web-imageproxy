# Go Translator in Front of imagor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Perl/Plack/ImageMagick service with a stdlib-only Go translator. It serves the existing `/i/[still/][W/][H/]<url>` API by signing requests to a private, stock imagor container.

**Architecture:** One Go package, `internal/proxy`, has four parts: request parsing (a port of `Web::ImageProxy::call` and `clean_url`), imagor path building and signing, magic-byte sniffing, and an `http.Handler` that proxies imagor's response and maps errors. `cmd/imageproxy` wires the handler to env config. imagor runs separately from a pinned `shumc/imagor` image.

**Tech Stack:** Go 1.27 (stdlib only, no cgo), `shumc/imagor` (libvips), Docker, docker compose, GitHub Actions → GHCR.

**Spec:** `docs/superpowers/specs/2026-10-26-go-imagor-rewrite-design.md`

## Global Constraints

- The translator listens on `:5007`. It is mounted at `/i`, and every other path returns 404 `not found`.
- Stdlib only in `go.mod`. No cgo (`CGO_ENABLED=0`).
- Error bodies are copied exactly from Perl:
  - 404: `Content-Type: text/plain`, body `not found`
  - 503: `Content-Type: text/plain`, body `error processing request`
- Signing uses HMAC-SHA1 over the path without a leading `/`, base64url **with padding** (`base64.URLEncoding`). The request goes to `<IMAGOR_URL>/<sig>/<path>`.
- Max upstream size is `10485760`, and the upstream timeout is `60s` (both set in imagor config).
- Auto-WebP and auto-AVIF stay off. There is no result storage and no file loader.
- Pin the `shumc/imagor` tag. Never use `latest`.
- Env: `IMAGOR_URL` (default `http://imagor:8000`), `IMAGOR_SECRET` (required; exit if empty), `LISTEN` (default `:5007`).
- The final branch removes `app.psgi`, `lib/`, `cpanfile`, `cpanfile.snapshot`, and `play_overlay.png`.

## Review Focus

1. **Image URL with a query string containing `/`, `//` or `&amp;`.** Perl splits and rejoins the whole raw URI, so `//` inside the query collapses to `/`. Port that exactly and don't "fix" it, because the CDN has cached the old URLs. Pinned in Task 1 (`TestParseRequest` "query with slashes").
2. **Upstream responses smaller than 1024 bytes.** Sniffing must work on short bodies (Peek returns EOF) and must not drop the bytes it peeked. Pinned in Task 4 (`TestHandlerSmallImage`).
3. **Upstream HTML or text served with a 200 on a no-size request (`raw()`).** imagor passes it through unchecked, so the translator must return 404 and never stream it. Pinned in Task 4 (`TestHandlerNonImage404`) and Task 6.
4. **The integration origin is unreachable because of imagor's private-network block.** The test compose must turn the block off. Production keeps it on. Pinned in Task 6 (the compose override, plus an assertion that the PNG fetch returns 200 before anything else is checked).
5. **A numeric segment too big for an int** (`/i/99999999999999999999/x.com/a.png`) returns 404. It must not panic or end up in the URL. Pinned in Task 1 ("overflow width").

---

### Task 1: Go module, request parsing, and `CleanURL`

**Files:**
- Create: `go.mod` (`module github.com/leedo/web-imageproxy`, `go 1.27`)
- Create: `internal/proxy/parse.go`
- Test: `internal/proxy/parse_test.go`

**Interfaces:**
- Produces:
  - `type Options struct { Still bool; Resize bool; Width, Height int }`. `Resize` is true when any numeric segment survived the 0/0 rule. Width and height use 0 to mean "absent or zero".
  - `func ParseRequest(requestURI string) (opts Options, imageURL string, ok bool)`. `requestURI` is the raw `r.RequestURI`. `ok=false` means the caller returns 404.
  - `func CleanURL(path string) (string, bool)`

- [ ] **Step 1: Write the failing table tests.** `TestParseRequest` has one row per case: `{name, uri, wantOpts, wantURL, wantOK}`.
  - `"/i/http://x.com/a.png"` → `{}`, `"http://x.com/a.png"`, ok
  - `"/i/https://x.com/a.png"` → `{}`, `"https://x.com/a.png"` (scheme repair)
  - `"/i/x.com/a.png"` → `"http://x.com/a.png"`
  - `"/i/HTTPS:/x.com/a.png"` → `"HTTPS://x.com/a.png"` (case-insensitive repair; the `https?` prefix check is also case-insensitive)
  - `"/i/200/x.com/a.png"` → `{Resize:true, Width:200}`
  - `"/i/200/100/x.com/a.png"` → `{Resize:true, Width:200, Height:100}`
  - `"/i/0/0/x.com/a.png"` → `{}` (0/0 cleared)
  - `"/i/0/x.com/a.png"` → `{Resize:true}` (width 0 alone is still a resize, as in Perl)
  - `"/i/still/x.com/a.gif"` → `{Still:true}`
  - `"/i/still/50/50/x.com/a.gif"` → `{Still:true, Resize:true, Width:50, Height:50}`
  - `"/i/200/still/x.com/a.png"` → `{Resize:true, Width:200}`, URL `"http://still/x.com/a.png"` (order matters, just like Perl)
  - query with slashes: `"/i/https://x.com/a.png?u=http://y.com//z&amp;b=1"` → `"https://x.com/a.png?u=http:/y.com/z&b=1"`
  - spaces: `"/i/x.com/a b.png"` → `"http://x.com/a%20b.png"`
  - overflow width: `"/i/99999999999999999999/x.com/a.png"` → ok=false
  - `"/i"`, `"/i/"`, `"/i/200/100/"` → ok=false
  - `"/i/favicon.ico"` → ok=false
  - `"/other/x.com/a.png"` → ok=false

  `TestCleanURL` checks `""` → false, `"/"` → false, `"//x.com/a"` → `"http://x.com/a"`.

- [ ] **Step 2: Run `go test ./internal/proxy/ -run 'TestParseRequest|TestCleanURL'`.** Expected: FAIL (undefined: ParseRequest).

- [ ] **Step 3: Implement `ParseRequest` and `CleanURL` in `parse.go`.**
  - Require the `/i/` prefix or an exact `/i`.
  - Treat a path starting with `favicon.ico` as not found.
  - Split the remainder on `/` and drop empty parts. Then apply `still`, then a digits-only segment (`strconv.Atoi`; an error returns ok=false), twice.
  - Join the rest with `/` and pass it to `CleanURL`.
  - `CleanURL` follows the spec steps in order. Whitespace is `\s`, matching Perl, and each whitespace character becomes `%20`.

- [ ] **Step 4: Run the same tests.** Expected: PASS.

- [ ] **Step 5: Commit** with `git add go.mod internal/proxy/parse*.go && git commit -m "Port request parsing and clean_url to Go"`.

### Task 2: imagor path building and signing

**Files:**
- Create: `internal/proxy/imagor.go`
- Test: `internal/proxy/imagor_test.go`

**Interfaces:**
- Consumes: `Options` (Task 1).
- Produces:
  - `func ImagorPath(opts Options, imageURL string) string` returns a path without a leading `/`.
  - `func Sign(secret, path string) string`
  - `func SignedURL(base, secret string, opts Options, imageURL string) string` returns `strings.TrimRight(base,"/") + "/" + Sign(secret,p) + "/" + p`.

- [ ] **Step 1: Write the failing tests.** `TestImagorPath` (with `u := "https://x.com/a.png?v=1&b=2"` and `e := url.QueryEscape(u)`):
  - `{}` → `"filters:raw()/" + e`
  - `{Resize:true, Width:200}` → `"fit-in/200x0/" + e`
  - `{Resize:true, Height:100}` → `"fit-in/0x100/" + e`
  - `{Resize:true, Width:200, Height:100}` → `"fit-in/200x100/" + e`
  - `{Still:true}` → `"filters:max_frames(1)/" + e`
  - `{Still:true, Resize:true, Width:50, Height:50}` → `"fit-in/50x50/filters:max_frames(1)/" + e`
  - Also assert `e` contains no `?`, `&` or `/`.

  `TestSign` computes the expected value independently: `hmac.New(sha1.New, []byte("s"))` over `"fit-in/200x0/abc"`, then `base64.URLEncoding.EncodeToString`. Assert equality, and assert the result ends with `=`. `TestSignedURL` checks the trailing-slash trim on `base`.

- [ ] **Step 2: Run `go test ./internal/proxy/ -run 'TestImagorPath|TestSign'`.** Expected: FAIL.
- [ ] **Step 3: Implement the three functions in `imagor.go`.** Escape with `url.QueryEscape`.
- [ ] **Step 4: Run the tests.** Expected: PASS. Real compatibility with imagor's verifier is proved in Task 6.
- [ ] **Step 5: Commit** with message "Build and sign imagor paths".

### Task 3: Magic-byte sniffing

**Files:**
- Create: `internal/proxy/sniff.go`
- Test: `internal/proxy/sniff_test.go`

**Interfaces:**
- Produces: `const SniffLen = 1024` and `func SniffMIME(b []byte) string`, which returns `""` when the bytes aren't a known image.

- [ ] **Step 1: Write the failing `TestSniffMIME` table.**
  - `"\x89PNG\r\n..."` → `image/png`
  - `"GIF89a..."` → `image/gif`
  - `"RIFF\x00\x00\x00\x00WEBPVP8 "` → `image/webp`
  - `"\x00\x00\x00\x18ftypheic...."` → `image/heic`
  - `"xPNG...."` → `image/png` (offset 1)
  - `"\xff\xd8\xff\xe0"` → `image/jpeg`
  - `"BM...."` → `""` (BMP dropped)
  - `"<html>"`, `""`, `"\xff"` → `""`
- [ ] **Step 2: Run `go test ./internal/proxy/ -run TestSniffMIME`.** Expected: FAIL.
- [ ] **Step 3: Implement `SniffMIME`.** Check in Perl's order: PNG, GIF, then bytes[0:4]=="RIFF" && bytes[8:12]=="WEBP", then bytes[8:12]=="heic", then PNG at offset 1, then JPEG `FFD8`. Bounds-check every slice.
- [ ] **Step 4: Run the test.** Expected: PASS.
- [ ] **Step 5: Commit** with message "Add magic-byte image sniffing".

### Task 4: Proxy handler

**Files:**
- Create: `internal/proxy/handler.go`
- Test: `internal/proxy/handler_test.go`

**Interfaces:**
- Consumes: `ParseRequest`, `SignedURL`, `SniffMIME`, `SniffLen`.
- Produces: `type Handler struct { ImagorURL, Secret string; Client *http.Client; Now func() time.Time; Log *log.Logger }`, which implements `http.Handler`.

**Behavior**, from the spec's response mapping:
- On a parse failure, return 404.
- Send a GET to `SignedURL` with the request's context.
- If the transport errors, or imagor returns 429 or 503, return 503.
- Any other non-200: log `"got <status> for <url>"` and return 404.
- On a 200: `bufio.NewReaderSize(body, SniffLen)` → `Peek(SniffLen)`. Accept `io.EOF` and use whatever bytes came back. If `SniffMIME` is empty, return 404.
- Otherwise:
  - set `Content-Type` from the sniff
  - copy `Content-Length` and `Cache-Control` from imagor
  - `ETag` = imagor's, else `fmt.Sprintf("%x", sha1.Sum([]byte(imageURL)))` (unquoted, like Perl)
  - `Last-Modified` = imagor's, else `h.Now().UTC().Format(http.TimeFormat)`
  - write 200, then `io.Copy` from the bufio reader
- Do not copy any other imagor headers.

- [ ] **Step 1: Write the failing tests** against a fake imagor (`httptest.Server`) that records the request path and replies from a per-test function:
  - `TestHandlerSignsPath`: GET `/i/200/x.com/a.png`. The fake sees `"/" + Sign(secret,p) + "/" + p` where `p = ImagorPath({Resize:true,Width:200}, "http://x.com/a.png")`.
  - `TestHandlerPassesImage`: the fake returns a 2000-byte PNG with `Content-Type: application/octet-stream`, `ETag: "abc"`, `Last-Modified: Mon, 02 Jan 2006 15:04:05 GMT`, `Cache-Control: max-age=604800`, and `X-Foo: 1`. The response is 200 and the body is byte-identical. `Content-Type` is `image/png`, `ETag`, `Last-Modified`, `Cache-Control` and `Content-Length: 2000` are passed through, and `X-Foo` is absent.
  - `TestHandlerSmallImage`: a 10-byte GIF body comes back intact with `image/gif`.
  - `TestHandlerDefaultHeaders`: imagor sends no ETag or Last-Modified. ETag is the sha1 hex of `"http://x.com/a.png"`, and Last-Modified is the formatted value of a fixed `Now`.
  - `TestHandlerNonImage404`: imagor returns 200 `<html>`. The response is 404 with body `not found` and `text/plain`.
  - `TestHandlerImagorError404`: imagor returns 400, 404 or 500 (subtests). Each gives 404 `not found`.
  - `TestHandler429Is503`: 503 with body `error processing request`.
  - `TestHandlerUnreachable503`: `ImagorURL` points at a closed server. Expect 503.
  - `TestHandlerBadPath404`: `/i/` and `/i/favicon.ico` return 404 without contacting imagor (the fake fails the test if it's hit).
- [ ] **Step 2: Run `go test ./internal/proxy/ -run TestHandler`.** Expected: FAIL.
- [ ] **Step 3: Implement `(*Handler).ServeHTTP`** following the behavior above. Add two helpers, `notFound(w)` and `unavailable(w)`, that write the exact error bodies.
- [ ] **Step 4: Run `go test ./internal/proxy/`.** Expected: all PASS. Also run `go vet ./...`, which should be clean.
- [ ] **Step 5: Commit** with message "Add imagor proxy handler".

### Task 5: Binary, container, compose, and Perl removal

**Files:**
- Create: `cmd/imageproxy/main.go`
- Rewrite: `Dockerfile`
- Create: `docker-compose.yml`
- Create: `.dockerignore` (`docs/`, `.git/`)
- Delete: `app.psgi`, `lib/`, `cpanfile`, `cpanfile.snapshot`, `play_overlay.png`
- Keep `.github/workflows/deploy.yml` as is. It already builds `./Dockerfile` as `ghcr.io/<repo>`.

**Interfaces:**
- Consumes: `proxy.Handler`.

- [ ] **Step 1: Implement `main.go`.**
  - Read `IMAGOR_URL`, `IMAGOR_SECRET` and `LISTEN` (defaults per Global Constraints). Call `log.Fatal` if the secret is empty.
  - Build the client: `&http.Client{Timeout: 65 * time.Second}`, with no redirect following (`CheckRedirect` returns `http.ErrUseLastResponse`).
  - Use `http.Server` with `ReadHeaderTimeout: 10s`. `Handler` is mounted at `/` and does its own `/i` check.
  - Handle SIGTERM with a graceful `Shutdown`.
- [ ] **Step 2: Pick the imagor pin.** Run `docker pull shumc/imagor:<newest release tag from https://github.com/cshum/imagor/releases>`. Then run `docker run --rm shumc/imagor:<tag> -h 2>&1 | grep -i -E 'user-agent|override-response|block|raw-on-error|max-allowed|queue|resolution'` to confirm the exact name of every env var in the spec's imagor config. They map to flags as upper-case with `-` → `_`. Record the User-Agent variable name; the spec expects something like `HTTP_LOADER_DEFAULT_USER_AGENT`. If a variable doesn't exist, stop and report it rather than guessing.
- [ ] **Step 3: Write the `Dockerfile`.**
  - Builder: `golang:1.27` stage running `CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /imageproxy ./cmd/imageproxy`.
  - Final: `gcr.io/distroless/static-debian12:nonroot` with `EXPOSE 5007` and `ENTRYPOINT ["/imageproxy"]`.
- [ ] **Step 4: Write `docker-compose.yml`.**
  - Service `imageproxy`: build `.`, ports `5007:5007`, env `IMAGOR_URL=http://imagor:8000` and `IMAGOR_SECRET=${IMAGOR_SECRET}`.
  - Service `imagor`: the pinned image with no published ports. Its env is exactly the spec's block, plus the User-Agent var set to `Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:109.0) Gecko/20100101 Firefox/112.0`, `IMAGOR_PROCESS_CONCURRENCY=4`, `IMAGOR_PROCESS_QUEUE_SIZE=50` and `VIPS_MAX_RESOLUTION=50000000`.
- [ ] **Step 5: Delete the Perl files** with `git rm -r app.psgi lib cpanfile cpanfile.snapshot play_overlay.png`.
- [ ] **Step 6: Verify.**
  - `docker build -t imageproxy-test .` succeeds.
  - `docker images imageproxy-test` shows the image under 15 MB.
  - `IMAGOR_SECRET=x docker compose up -d`, then `curl -si localhost:5007/i/` returns `404` with body `not found`. Then run `docker compose down`.
- [ ] **Step 7: Commit** with message "Replace Perl service with Go translator and imagor compose".

### Task 6: End-to-end test against real imagor

**Files:**
- Create: `internal/proxy/e2e_test.go` (build tag `//go:build e2e`)
- Create: `docker-compose.e2e.yml`: the `imagor` service from Task 5 with port `8000:8000`, `HTTP_LOADER_BLOCK_PRIVATE_NETWORKS=0`, `HTTP_LOADER_BLOCK_LOOPBACK_NETWORKS=0`, `extra_hosts: ["host.docker.internal:host-gateway"]` and `IMAGOR_SECRET=e2e`.
- Modify: `.github/workflows/deploy.yml`. Before the build step, add a `go test ./...` step, then a `docker compose -f docker-compose.e2e.yml up -d` step, then `go test -tags e2e ./internal/proxy/` (with the `setup-go` action, `go-version: '1.27'`).

**Interfaces:**
- Consumes: `proxy.Handler` (in-process, with `ImagorURL=http://localhost:8000` and `Secret=e2e`).

**Origin fixtures**, served by an `httptest` server listening on `0.0.0.0` and addressed as `http://host.docker.internal:<port>/...`. Generate them in the test with stdlib encoders:
- `/big.png` is 800×600. `/small.png` is 50×40.
- `/anim.gif` has 3 frames of 100×100 (`gif.EncodeAll`).
- `/rot.jpg` is a 200×100 JPEG with EXIF orientation 6. A helper, `withOrientation(jpg []byte, o uint16) []byte`, inserts this APP1 segment right after the `FFD8` SOI:
  `FFE1`, len(2, big-endian, = 2+6+26), `"Exif\x00\x00"`, then TIFF `"MM\x00\x2A\x00\x00\x00\x08"`, IFD count `\x00\x01`, entry tag `\x01\x12` type `\x00\x03` count `\x00\x00\x00\x01` value `o` (2 bytes) + `\x00\x00`, next-IFD `\x00\x00\x00\x00`.
- `/page.html` returns `<html>` with a 200. `/missing.png` returns 404.
- `/huge.png` is a PNG signature followed by 11 MB of zeros.

- [ ] **Step 1: Write the tests.** Each decodes the response with `image.DecodeConfig` or `gif.DecodeAll`.
  - `/i/<origin>/big.png` returns 200, `image/png`, and 800×600. This assertion runs first and fails with the hint "imagor can't reach origin (private-network block?)".
  - `/i/200/<origin>/big.png` → 200×150. `/i/200/100/...big.png` → 133×100.
  - `/i/200/<origin>/small.png` → 50×40 (no upscale).
  - `/i/50/<origin>/anim.gif` → still 3 frames, 50×50.
  - `/i/still/<origin>/anim.gif` → a GIF with exactly 1 frame.
  - `/i/50/<origin>/rot.jpg` → 50×100 (auto-rotated to 100×200, then fitted into width 50).
  - `/page.html` (no size and with a size), `/missing.png` and `/huge.png` each return 404 `not found`.
  - The `big.png` resize response carries a non-empty `Cache-Control`.
- [ ] **Step 2: Run `docker compose -f docker-compose.e2e.yml up -d && go test -tags e2e ./internal/proxy/ -v`.** Expected: PASS. If the signing test fails here with imagor 403s, fix `Sign` in Task 2's code, not the test.
- [ ] **Step 3: Run `docker compose -f docker-compose.e2e.yml down`.** Commit with message "Add end-to-end tests against imagor".
