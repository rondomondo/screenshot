#!/bin/bash
set -euo pipefail

[[ "${DEBUG:-0}" == "1" ]] && set -x

PW_CLI=/app/node_modules/playwright-chromium/cli.js
PW_MCP_CLI=/app/node_modules/playwright-core/cli.js
SSC=/app/ssc.py
SCREENSHOTS_DIR=${SCREENSHOTS_DIR:-/screenshots}
PDFS_DIR=${PDFS_DIR:-/pdfs}

# 3000 is Playwright MCP's default but conflicts with Grafana; override via MCP_PORT env var.
MCP_PORT=${MCP_PORT:-3000}
MCP_URL="http://localhost:${MCP_PORT}/sse"
MCP_HEALTH_URL="http://localhost:${MCP_PORT}/mcp"
MCP_PID=""

BOLD='\033[1m'
GREEN='\033[32m'
CYAN='\033[36m'
RED='\033[31m'
RESET='\033[0m'

log()  { printf "${CYAN}[screenshot:$(hostname)]${RESET} %s\n" "$*" >&2; }
ok()   { printf "${GREEN}[screenshot:$(hostname)]${RESET} %s\n" "$*" >&2; }
fail() { printf "${RED}[screenshot:$(hostname)]${RESET} %s\n" "$*" >&2; exit 1; }

usage() {
  cat >&2 <<EOF
Usage: screenshot <command> [options] <target>

Commands:
  screenshot   Capture a PNG screenshot
  pdf          Save page as PDF
  install      Emit an installer script (pipe to sh)
  uninstall    Emit an uninstaller script (pipe to sh)

Target:
  A URL (https://...) or a local HTML file path (relative to /html inside the container)

Options:
  --convert <fmt>              Convert output to fmt after capture (webp, jpeg, gif, ...)
  --out-dir <dir>              Override output directory (default: /screenshots or /pdfs)
  --wait-for-timeout <ms>      Wait before capture; maps to --pause for MCP client (default: 3000)
  --viewport-size <WxH>        Viewport size (default: 1032x1376)
  --device-scale-factor <n>    Device pixel ratio for high-DPI output (default: 2, screenshot only)
  --user-agent <string>        Browser user-agent string
  --device <name>              Playwright device to emulate (overrides viewport, scale, UA)
  --full-page                  Capture full page (screenshot only, default: on)
  --no-scroll                  Capture viewport only (no pre-render scroll)
  --ignore-https-errors        Ignore TLS errors (default: on)
  --paper-format <fmt>         Paper format for PDF (default: A4)
  --headers-footers            Include browser-generated header and footer in PDF (default: off)
  --wait-for <text>        Wait for text to appear before capture (MCP mode only)
  --storage-state <path>   Path to Playwright storageState JSON (MCP mode only)
  --custom-selector <sel>  CSS selector for popup dismissal (MCP mode only, repeatable)
  Any other --flag value pairs are passed through to the MCP client or playwright.

EOF
  exit 1
}

# Derive a kebab-case filename stem from a URL or file path.
# https://some.domain.com/a/path/resource.html -> some-domain-com-a-path-resource-html
# /html/some-file.html                         -> some-file
derive_stem() {
  local target="$1"
  local stem

  if [[ "$target" =~ ^https?:// ]]; then
    stem="${target#*://}"
    stem="${stem%%\?*}"
    stem="${stem%%\#*}"
    stem=$(printf '%s' "$stem" | tr -cs 'a-zA-Z0-9' '-' | sed 's/^-//;s/-$//')
  else
    local base
    base=$(basename "$target")
    stem="${base%.*}"
  fi

  printf '%s' "${stem,,}"
}

mcp_start() {
  log "Starting embedded MCP server on port ${MCP_PORT}..."

  # Write a minimal playwright MCP config so we can set deviceScaleFactor and viewport.
  # The VIEWPORT and DEVICE_SCALE_FACTOR variables are set before mcp_start is called.
  local vw vh
  IFS='x' read -r vw vh <<< "$VIEWPORT"
  local mcp_config_file="/tmp/mcp-config.json"
  printf '{"browser":{"contextOptions":{"deviceScaleFactor":%s,"viewport":{"width":%s,"height":%s}}}}' \
    "$DEVICE_SCALE_FACTOR" "$vw" "$vh" > "$mcp_config_file"

  local exec_path_arg=()
  if [[ -n "${PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH:-}" ]]; then
    exec_path_arg=(--executable-path "$PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH")
  fi
  node "$PW_MCP_CLI" mcp \
    --headless \
    --isolated \
    --port "$MCP_PORT" \
    --browser chromium \
    --host 127.0.0.1 \
    --allowed-hosts '*' \
    --allow-unrestricted-file-access \
    --config "$mcp_config_file" \
    "${exec_path_arg[@]}" \
    &>/tmp/mcp-server.log &
  MCP_PID=$!

  local attempts=20
  local delay=1
  local i
  for i in $(seq 1 $attempts); do
    if curl -fs --max-time 2 -X POST \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"healthcheck","version":"1"}}}' \
        "$MCP_HEALTH_URL" >/dev/null 2>&1; then
      ok "MCP server ready (pid ${MCP_PID})"
      return 0
    fi
    sleep "$delay"
  done

  fail "MCP server did not become ready after $((attempts * delay))s. Log:\n$(cat /tmp/mcp-server.log)"
}

mcp_stop() {
  if [[ -n "$MCP_PID" ]]; then
    kill "$MCP_PID" 2>/dev/null || true
    wait "$MCP_PID" 2>/dev/null || true
    MCP_PID=""
  fi
}

# Parse command
[[ $# -lt 1 ]] && usage
COMMAND="$1"; shift

case "$COMMAND" in
  install)   exec /install.sh "$@" ;;
  uninstall) exec /uninstall.sh "$@" ;;
esac

[[ "$COMMAND" != "screenshot" && "$COMMAND" != "pdf" && "$COMMAND" != "element" ]] && {
  echo "Unknown command: $COMMAND" >&2; usage
}

# Defaults
CONVERT_FMT=""
OUT_DIR=""
SCROLL=true
WAIT_TIMEOUT_MS=3000
VIEWPORT="1032x1376"
PAPER_FORMAT="A4"
DISPLAY_HEADER_FOOTER=false
DEVICE_SCALE_FACTOR="2"
USER_AGENT=""
DEVICE=""

# ssc.py forwarded args (built up as we parse)
SSC_ARGS=()
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --convert)
      [[ $# -lt 2 ]] && fail "--convert requires a format argument"
      CONVERT_FMT="$2"; shift 2 ;;
    --out-dir)
      [[ $# -lt 2 ]] && fail "--out-dir requires a path argument"
      OUT_DIR="$2"; shift 2 ;;
    --wait-for-timeout)
      [[ $# -lt 2 ]] && fail "--wait-for-timeout requires a value"
      WAIT_TIMEOUT_MS="$2"; shift 2 ;;
    --viewport-size)
      [[ $# -lt 2 ]] && fail "--viewport-size requires a value"
      VIEWPORT="$2"; shift 2 ;;
    --paper-format)
      [[ $# -lt 2 ]] && fail "--paper-format requires a value"
      PAPER_FORMAT="$2"; shift 2 ;;
    --headers-footers)
      DISPLAY_HEADER_FOOTER=true; shift ;;
    --no-headers-footers)
      DISPLAY_HEADER_FOOTER=false; shift ;;
    --device-scale-factor)
      [[ $# -lt 2 ]] && fail "--device-scale-factor requires a value"
      DEVICE_SCALE_FACTOR="$2"; shift 2 ;;
    --full-page)
      shift ;;
    --ignore-https-errors)
      shift ;;
    --no-scroll)
      SCROLL=false; shift ;;
    --wait-for)
      [[ $# -lt 2 ]] && fail "--wait-for requires a text argument"
      SSC_ARGS+=(--wait-for "$2"); shift 2 ;;
    --storage-state)
      [[ $# -lt 2 ]] && fail "--storage-state requires a path"
      SSC_ARGS+=(--storage-state "$2"); shift 2 ;;
    --custom-selector)
      [[ $# -lt 2 ]] && fail "--custom-selector requires a CSS selector"
      SSC_ARGS+=(--custom-selector "$2"); shift 2 ;;
    --user-agent)
      [[ $# -lt 2 ]] && fail "--user-agent requires a string argument"
      USER_AGENT="$2"; shift 2 ;;
    --device)
      [[ $# -lt 2 ]] && fail "--device requires a device name"
      DEVICE="$2"; shift 2 ;;
    --*)
      # Unknown flags: pass through to ssc.py
      SSC_ARGS+=("$1")
      if [[ $# -ge 2 && "$2" != --* ]]; then
        SSC_ARGS+=("$2"); shift
      fi
      shift ;;
    *)
      TARGET="$1"; shift ;;
  esac
done

[[ -z "$TARGET" ]] && fail "No target specified. Provide a URL or HTML file path."

# Resolve local file targets to file:///html/<file>
RESOLVED_TARGET="$TARGET"
if [[ ! "$TARGET" =~ ^https?:// ]]; then
  if [[ "$TARGET" != /* ]]; then
    RESOLVED_TARGET="/html/$TARGET"
  fi
  [[ -f "$RESOLVED_TARGET" ]] || fail "Local file not found: $RESOLVED_TARGET"
  RESOLVED_TARGET="file://$RESOLVED_TARGET"
fi

# Determine output directory and extension
if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR=$([[ "$COMMAND" == "pdf" ]] && echo "$PDFS_DIR" || echo "$SCREENSHOTS_DIR")
fi
mkdir -p "$OUT_DIR"

EXT=$([[ "$COMMAND" == "pdf" ]] && echo "pdf" || echo "png")
STEM=$(derive_stem "$TARGET")
OUT_FILE="${OUT_DIR}/${STEM}.${EXT}"

log "command:  $COMMAND"
log "target:   $TARGET"
log "output:   $OUT_FILE"

# Convert --wait-for-timeout ms to --pause ms (ssc.py uses per-scroll-step pause, not total wait)
PAUSE_MS=$(( WAIT_TIMEOUT_MS / 6 ))
[[ "$PAUSE_MS" -lt 200 ]] && PAUSE_MS=200

SSC_ARGS+=(--out-dir "$OUT_DIR" --viewport-size "$VIEWPORT")
if [[ "$COMMAND" == "screenshot" || "$COMMAND" == "pdf" ]]; then
  SSC_ARGS+=(--pause "$PAUSE_MS")
  [[ "$SCROLL" == "false" ]] && SSC_ARGS+=(--no-scroll)
fi
[[ "$COMMAND" == "screenshot" ]] && SSC_ARGS+=(--device-scale-factor "$DEVICE_SCALE_FACTOR")
[[ "$COMMAND" == "pdf" ]] && SSC_ARGS+=(--paper-format "$PAPER_FORMAT")
[[ "$COMMAND" == "pdf" && "$DISPLAY_HEADER_FOOTER" == "true" ]] && SSC_ARGS+=(--headers-footers)
[[ "$COMMAND" == "element" ]] && SSC_ARGS+=(--device-scale-factor "$DEVICE_SCALE_FACTOR")
[[ -n "$USER_AGENT" ]] && SSC_ARGS+=(--user-agent "$USER_AGENT")
[[ -n "$DEVICE" ]] && SSC_ARGS+=(--device "$DEVICE")

trap mcp_stop EXIT
mcp_start

log "Running ssc.py ${COMMAND}..."
uv run --script "$SSC" "$COMMAND" "${SSC_ARGS[@]}" --url "$MCP_URL" "$RESOLVED_TARGET"

ok "saved ${OUT_FILE#/}"

# Optional post-conversion
if [[ -n "$CONVERT_FMT" ]]; then
  FINAL_FILE="${OUT_FILE%.*}.${CONVERT_FMT}"
  log "converting $OUT_FILE -> $FINAL_FILE"
  convert "$OUT_FILE" "$FINAL_FILE"
  rm -f "$OUT_FILE"
  ok "converted to ${FINAL_FILE#/}"
fi
