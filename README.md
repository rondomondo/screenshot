# screenshot

Full-page screenshots and PDFs from URLs or local HTML files, via a Docker-wrapped Playwright
(Chromium). No browser installation needed on the host.

## Try it now

No install needed - just Docker:

```bash
docker run --rm \
  -v $(pwd)/screenshots:/screenshots \
  ghcr.io/rondomondo/screenshot:latest \
  screenshot https://en.wikipedia.org/wiki/Special:Random
```

Your screenshot lands in `./screenshots/`. Swap `screenshot` for `pdf` and mount `./pdfs:/pdfs`
to get a PDF instead.

## Install `url2pdf` and `url2image`

Install lightweight host wrappers that call Docker for you:

```bash
docker run --rm ghcr.io/rondomondo/screenshot:latest install | sh
```

Then from any directory:

```bash
url2image https://en.wikipedia.org/wiki/Special:Random
url2pdf   https://en.wikipedia.org/wiki/Special:Random
```

Output lands in `./screenshots/` and `./pdfs/` relative to your current directory.
To uninstall: `docker run --rm ghcr.io/rondomondo/screenshot:latest uninstall | sh`

## Common options

Both `url2image` and `url2pdf` accept flags before or after the target:

```bash
# Screenshot
url2image https://example.com --convert webp
url2image https://example.com --no-scroll
url2image https://example.com --viewport-size 1920x1080

# PDF
url2pdf https://example.com --convert jpeg
url2pdf https://example.com --paper-format Letter
url2pdf https://example.com --wait-for-timeout 5000
```

Set `IMAGE_TAG` to pin a specific image version:

```bash
IMAGE_TAG=0.0.21 url2pdf https://example.com
```

Set `DEBUG=1` to print the full `docker run` command before it executes:

```bash
DEBUG=1 url2pdf https://example.com
```

## All options

```
Options:
  --convert <fmt>             Convert output after capture (webp, jpeg, gif, ...)
  --wait-for-timeout <ms>     Wait before capture (default: 3000)
  --viewport-size <WxH>       Viewport dimensions (default: 1032x1376)
  --paper-format <fmt>        Paper format for PDF (default: A4)
  --no-scroll                 Capture viewport only, skip full-page scroll
  --ignore-https-errors       Ignore TLS errors
  --out-dir <dir>             Override output directory
  --device-scale-factor <n>   Device pixel ratio for high-DPI output (default: 2, screenshot only)
  --wait-for <text>           Wait for text to appear before capture (MCP mode only)
  --storage-state <path>      Playwright storageState JSON for authenticated sessions
  --custom-selector <sel>     CSS selector for popup dismissal (repeatable)

Environment:
  IMAGE_TAG                   Docker image tag (default: latest)
  IMAGE_REGISTRY              Registry host (default: ghcr.io)
  IMAGE_REPO                  Image repository (default: rondomondo/screenshot)
  DEBUG                       Set to 1 to trace the docker command
```

## Local HTML files

Place HTML files in `./html/` and reference them by filename:

```bash
url2image my-page.html
url2pdf   my-page.html
```

The directory is mounted read-only at `/html` inside the container. The output filename is derived
from the basename, e.g. `my-page.html` -> `my-page.png`.

## MCP server

The image includes a long-lived [Playwright MCP](https://playwright.dev/docs/mcp) server that
AI agents can drive over HTTP on port 3000. `make screenshot` and `make pdf` use this path
via `ssc.py`, which adds incremental page scrolling to trigger lazy-loaded assets and automatic
popup/overlay dismissal before capture.

```bash
make mcp-up                   # start (default session)
make mcp-up SESSION=mysite    # start with a named session (persists cookies/storage)
make mcp-down                 # stop
make status                   # show running containers and health
make mcp-shell                # open bash inside the container with /workspace mounted
```

Sessions are stored as JSON under `./workspace/sessions/`. A missing file is created as `{}` on
first start.

### Connect an MCP client

Point your client at `http://localhost:3000` (SSE transport) or `http://localhost:3000/mcp`
(HTTP transport). The server runs headless Chromium in isolated mode.

## Usage via Make

```bash
make screenshot TARGET=https://example.com
make screenshot TARGET=https://example.com ARGS="--convert webp"
make screenshot TARGET=my-page.html

make pdf TARGET=https://example.com
make pdf TARGET=https://example.com ARGS="--paper-format Letter"
```

If the MCP server is not already running, `make screenshot` and `make pdf` start it automatically
and tear it down when done.

## Usage via Docker directly

```bash
# Screenshot
docker run --rm \
  -v $(pwd)/screenshots:/screenshots \
  ghcr.io/rondomondo/screenshot:latest \
  screenshot https://example.com

# PDF
docker run --rm \
  -v $(pwd)/pdfs:/pdfs \
  ghcr.io/rondomondo/screenshot:latest \
  pdf https://example.com

# Local HTML file
docker run --rm \
  -v $(pwd)/screenshots:/screenshots \
  -v $(pwd)/html:/html:ro \
  ghcr.io/rondomondo/screenshot:latest \
  screenshot my-page.html

# DEBUG=1 traces every command inside the container
docker run --rm -e DEBUG=1 \
  -v $(pwd)/screenshots:/screenshots \
  ghcr.io/rondomondo/screenshot:latest \
  screenshot https://example.com
```

## Volumes

| Path           | Purpose                                    |
|----------------|--------------------------------------------|
| `/screenshots` | PNG output from `screenshot` command       |
| `/pdfs`        | PDF output from `pdf` command              |
| `/html`        | Local HTML files (mounted read-only)       |
| `/workspace`   | MCP session state (`sessions/<name>.json`) |

## Building and releasing

```bash
make build        # single-arch image for local testing
make release      # bump patch version + multi-platform push to ghcr.io
make push         # multi-platform push without bumping version
make bump         # increment patch version in VERSION only
```

The current version is tracked in `VERSION`. `make inspect` shows the manifest platforms for
the remote `:latest` image.

## Requirements

- Docker
- `uv` (required for `make screenshot` / `make pdf` via the MCP client)
- GNU Make (optional but convenient)
- `docker buildx` with a multi-platform builder (only needed for `make release`)

## Make targets

Run `make help` for the full list. Key targets:

```
make install        Install url2pdf and url2image to /usr/local/bin (or ~/.local/bin)
make uninstall      Remove url2pdf, url2image, and url2capture
make test           Run the unit test suite (uv run pytest)
make clean-all      Remove image tags, builder, generated output, and caches
```

## Image details

- Base: `node:22-slim`
- Playwright Chromium bundled via `npm ci`
- ImageMagick for post-capture format conversion
- Python 3.12 + `uv` for `ssc.py`
- Default viewport: 1032x1376 at 2x device pixel ratio
- Default wait before capture: 3000 ms
- Published to `ghcr.io/rondomondo/screenshot` for `linux/amd64`
