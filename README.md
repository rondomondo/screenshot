# screenshot

A lightweight Docker image that wraps [Playwright](https://playwright.dev/) (Chromium only) to capture
full-page screenshots and PDFs from URLs or local HTML files. ImageMagick is included for
post-capture format conversion.

This image is published to `ghcr.io/rondomondo/screenshot` for `linux/amd64` and `linux/arm64`.

## What it does

- `screenshot` - captures a full-page PNG (or converts to webp/jpeg/gif/etc via ImageMagick)
- `pdf` - saves a page as a PDF with configurable paper format (A4, Letter, etc)
- `mcp` - runs a long-lived [Playwright MCP](https://playwright.dev/docs/mcp) server over HTTP/SSE on port 3000
- `install` / `uninstall` - emit a host installer script (pipe to `sh`)

Targets can be public URLs or local HTML files mounted into the container.

## Requirements

- Docker
- GNU Make (optional but convenient)
- `uv` (required for `make screenshot` / `make pdf` via the MCP client)
- `docker buildx` with a multi-platform builder (only needed for `make release`)

## Quick install

Install `url2pdf` and `url2image` directly onto your host:

```bash
docker run --rm ghcr.io/rondomondo/screenshot:latest install | sh
```

Then use them from any directory:

```bash
url2pdf https://en.wikipedia.org/wiki/Special:Random
url2image https://en.wikipedia.org/wiki/Special:Random --convert webp
```

Output lands in `./pdfs/` and `./screenshots/` relative to wherever you run the command.
Pass `DEBUG=1` to print the full `docker run` invocation before it executes:

```bash
DEBUG=1 url2pdf https://en.wikipedia.org/wiki/Special:Random
```

To uninstall:

```bash
docker run --rm ghcr.io/rondomondo/screenshot:latest uninstall | sh
```

## url2pdf and url2image

The installed wrappers each accept a URL or local HTML filename plus any entrypoint options.
Flags may appear before or after the target.

```bash
# Save as PDF
url2pdf https://en.wikipedia.org/wiki/Special:Random
url2pdf https://en.wikipedia.org/wiki/Special:Random --convert jpeg
url2pdf https://en.wikipedia.org/wiki/Special:Random --paper-format Letter --wait-for-timeout 5000

# Capture screenshot
url2image https://en.wikipedia.org/wiki/Special:Random
url2image https://en.wikipedia.org/wiki/Special:Random --convert webp
url2image https://en.wikipedia.org/wiki/Special:Random --no-scroll        # viewport only, no full-page scroll
url2image https://en.wikipedia.org/wiki/Special:Random --convert webp --viewport-size 1920x1080
```

Both commands:
- Create `./pdfs/`, `./screenshots/` in the current directory automatically
- Mount `./html/` only when the target is a local file path (not a URL)
- Always pull the latest image (`--pull always`)

## Usage via Make

`make screenshot` and `make pdf` use `ssc.py`, a smarter MCP-driven client that adds
DuckDuckGo AutoConsent, incremental page scrolling to trigger lazy-loaded assets, and
dynamic popup/overlay dismissal before capture.

```bash
# Screenshot a URL
make screenshot TARGET=https://en.wikipedia.org/wiki/Special:Random

# Screenshot and convert to WebP
make screenshot TARGET=https://en.wikipedia.org/wiki/Special:Random ARGS="--convert webp"

# Save a page as PDF (A4 by default)
make pdf TARGET=https://en.wikipedia.org/wiki/Special:Random

# PDF with Letter paper size
make pdf TARGET=https://en.wikipedia.org/wiki/Special:Random ARGS="--paper-format Letter"

# Screenshot a local HTML file (place it in ./html/ first)
make screenshot TARGET=my-page.html
```

Output lands in `./screenshots/` or `./pdfs/`. Filenames are derived from the URL or file name,
e.g. `https://en.wikipedia.org/wiki/Special:Random/foo/bar` -> `example-com-foo-bar.png`.

If the MCP server is not already running, `make screenshot` / `make pdf` will spin it up
automatically and tear it down again when done.

## Usage via Docker directly

```bash
docker run --rm \
  -v $(pwd)/screenshots:/screenshots \
  -v $(pwd)/pdfs:/pdfs \
  ghcr.io/rondomondo/screenshot:latest \
  screenshot https://en.wikipedia.org/wiki/Special:Random
```

For local HTML files, also mount `./html/`:

```bash
docker run --rm \
  -v $(pwd)/screenshots:/screenshots \
  -v $(pwd)/pdfs:/pdfs \
  -v $(pwd)/html:/html:ro \
  ghcr.io/rondomondo/screenshot:latest \
  screenshot my-page.html
```

Pass `DEBUG=1` to trace every command inside the container:

```bash
docker run --rm -e DEBUG=1 \
  -v $(pwd)/screenshots:/screenshots \
  -v $(pwd)/pdfs:/pdfs \
  ghcr.io/rondomondo/screenshot:latest \
  screenshot https://en.wikipedia.org/wiki/Special:Random
```

## Entrypoint options

```
Usage: screenshot <command> [options] <target>

Commands:
  screenshot   Capture a PNG screenshot
  pdf          Save page as PDF
  install      Emit an installer script (pipe to sh)
  uninstall    Emit an uninstaller script (pipe to sh)

Target:
  A URL (https://...) or a local HTML filename (relative to /html inside the container)

Options:
  --convert <fmt>          Convert output after capture (webp, jpeg, gif, ...)
  --out-dir <dir>          Override output directory
  --wait-for-timeout <ms>  Wait before capture (default: 3000)
  --viewport-size <WxH>    Viewport size (default: 1032x1376)
  --full-page              Capture full page (screenshot only, default: on)
  --no-scroll              Capture viewport only, no full-page scroll (screenshot only)
  --ignore-https-errors    Ignore TLS errors (default: on)
  --paper-format <fmt>     Paper format for PDF (default: A4)
```

Any unrecognised `--flag value` pairs are passed through directly to Playwright.

## Local HTML files

Place HTML files in `./html/` and reference them by filename:

```bash
make screenshot TARGET=my-page.html
```

The directory is mounted read-only at `/html` inside the container. The output filename is derived
from the basename without extension, e.g. `my-page.html` -> `my-page.png`.

## MCP server

The image also ships with `playwright-mcp`, enabling AI agents to control a browser over
HTTP/SSE on port 3000.

### Start the MCP server

```bash
# Start with the default session
make mcp-up

# Start with a named session (persists cookies/storage across restarts)
make mcp-up SESSION=mysite
```

Sessions are stored as JSON files under `./workspace/sessions/`. A missing session file is
created automatically as an empty `{}` on first start.

### Stop the MCP server

```bash
make mcp-down
```

### Inspect the workspace

```bash
make mcp-shell   # opens bash inside the container with /workspace mounted
```

### Connect an MCP client

Point your MCP client at `http://localhost:3000` (SSE transport). The server runs headless
Chromium in isolated mode.

## Building

```bash
# Build single-arch image for local testing
make build

# Bump patch version, build multi-platform (amd64 + arm64), and push to ghcr.io
make release

# Build and push without bumping the version
make push
```

The current version is tracked in `VERSION`. `make bump` increments the patch component.

## Make targets

```
make help              Show all available targets
make install           Install url2pdf and url2image to /usr/local/bin (DESTDIR= to override)
make uninstall         Remove url2pdf, url2image, and url2capture from DESTDIR
make build             Build single-arch image locally
make release           Bump version + multi-platform push to ghcr.io
make push              Multi-platform push (no version bump)
make bump              Increment patch version in VERSION
make screenshot        Take a screenshot via MCP client (TARGET= required)
make pdf               Save a PDF via MCP client (TARGET= required)
make mcp-up            Start the MCP server (SESSION= selects the session file)
make mcp-down          Stop the MCP server
make mcp-shell         Open a bash shell in the MCP container
make docker-shell      Open a bash shell inside the image
make status            Show running containers and MCP health
make size              Show local image sizes
make version           Print current version
make inspect           Show manifest platforms for :latest
make test              Run the unit test suite
make clean             Remove local image tags
make clean-builder     Remove the buildx builder instance
make clean-generated   Empty screenshots/ and pdfs/ output directories
make clean-python      Remove Python caches
make clean-node        Remove node_modules
make clean-all         Run all clean targets
```

## Volumes

| Path           | Purpose                                         |
|----------------|-------------------------------------------------|
| `/screenshots` | PNG output from `screenshot` command            |
| `/pdfs`        | PDF output from `pdf` command                   |
| `/html`        | Local HTML files (mounted read-only)            |
| `/workspace`   | MCP session state (`sessions/<name>.json`)      |

## Image details

- Base: `node:22-slim`
- Playwright Chromium installed via `npm ci`
- ImageMagick available for post-capture format conversion
- Default viewport: 1032x1376
- Default wait before capture: 3000 ms
