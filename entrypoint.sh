#!/bin/bash
set -euo pipefail

is_truthy() { case "${1,,}" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac; }

# Precedence matches ssc.py: --log-level, then LOG_LEVEL, then DEBUG=1 (-> DEBUG), then WARNING.
LOG_LEVEL=${LOG_LEVEL:-}
if [[ -z "$LOG_LEVEL" ]] && is_truthy "${DEBUG:-0}"; then LOG_LEVEL=DEBUG; fi
if is_truthy "${DEBUG:-0}"; then set -x; fi

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

print_help() {
  cat >&2 <<EOF
Usage: screenshot <command> [options] <target>

Commands:
  screenshot   Capture a PNG screenshot
  element      Capture a single CSS-selected element as PNG (requires --selector)
  pdf          Save page as PDF
  devices      List the Playwright devices usable with --device
  device-info  Print the descriptor for one device: device-info '<name>'
  install      Emit an installer script (pipe to sh)
  uninstall    Emit an uninstaller script (pipe to sh)
  mcp          Start the Playwright MCP server (passes all args to node playwright-core/cli.js mcp)
  help         Show this help message

Target:
  A URL (https://...) or a local HTML file path (relative to /html inside the container)

Options:
  --convert <fmt>              Convert image output to fmt after capture (webp, jpeg, gif, ...); ignored for pdf
  --out-dir <dir>              Override output directory (default: /screenshots or /pdfs)
  --wait-for-timeout <ms>      Wait before capture; maps to --pause for MCP client (default: 3000)
  --viewport-size <WxH>        Viewport size (default: 1032x1376)
  --device-scale-factor <n>    Device pixel ratio for high-DPI output (default: 2, screenshot only)
  --user-agent <string>        Browser user-agent string
  --device <name>              Playwright device to emulate (overrides viewport, scale, UA)
  --wait-for, -w <text>        Wait for this text to appear before capture
  --no-scroll                  Capture viewport only (no pre-render scroll)
  --paper-format <fmt>         Paper format for PDF (default: A4)
  --headers-footers            Include browser-generated header and footer in PDF (default: off)
  --unclip                     Free fixed-height scroll containers before PDF render (default: on)
  --no-unclip                  Disable scroll-container freeing before PDF render
  --log-level <level>          DEBUG, INFO, WARNING, ERROR or CRITICAL (default: WARNING)
  --storage-state <path>       Path to Playwright storageState JSON (MCP mode only)
  --custom-selector <sel>      CSS selector for popup dismissal (MCP mode only, repeatable)
  --dismiss-popups / --no-dismiss-popups   Toggle cookie and popup dismissal (default: on, off for element)
  --selector <css>             Element to capture (element command)
  --hide <css>                 Element to hide before capture (element and pdf, repeatable)
  Short forms: -o --out-dir, -c --custom-selector, -H --hide, -s --selector (element) or --storage-state
  Any other --flag value pairs are passed through to ssc.py. The target may appear anywhere, including last.

Logging:
  Default is WARNING. Raise verbosity with any of (first match wins):
    --log-level INFO|DEBUG     per run
    LOG_LEVEL=INFO|DEBUG       environment variable
    DEBUG=1                    LOG_LEVEL=DEBUG plus shell tracing (set -x) and the MCP server log on exit

MCP server (standalone):
  docker run --rm -p 3000:3000 ghcr.io/rondomondo/screenshot mcp \\
    --headless --isolated --port 3000 --browser chromium \\
    --host 0.0.0.0 --allowed-hosts '*' --allow-unrestricted-file-access

EOF
}

usage() {
  print_help
  exit 1
}

# Derive a kebab-case filename stem from a URL or file path.
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

  # Write a minimal playwright MCP config so context options are baked in before any navigation.
  # VIEWPORT, DEVICE_SCALE_FACTOR, USER_AGENT, IS_MOBILE, and HAS_TOUCH are fully resolved before mcp_start is called.
  local vw vh
  IFS='x' read -r vw vh <<< "$VIEWPORT"
  local mcp_config_file="/tmp/mcp-config.json"
  if [[ -n "$USER_AGENT" ]]; then
    printf '{"browser":{"contextOptions":{"deviceScaleFactor":%s,"viewport":{"width":%s,"height":%s},"userAgent":%s,"isMobile":%s,"hasTouch":%s}}}' \
      "$DEVICE_SCALE_FACTOR" "$vw" "$vh" "$(printf '%s' "$USER_AGENT" | uv run python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
      "${IS_MOBILE:-false}" "${HAS_TOUCH:-false}" \
      > "$mcp_config_file"
  else
    printf '{"browser":{"contextOptions":{"deviceScaleFactor":%s,"viewport":{"width":%s,"height":%s},"isMobile":%s,"hasTouch":%s}}}' \
      "$DEVICE_SCALE_FACTOR" "$vw" "$vh" "${IS_MOBILE:-false}" "${HAS_TOUCH:-false}" > "$mcp_config_file"
  fi

  local exec_path_arg=()
  if [[ -n "${PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH:-}" ]]; then
    exec_path_arg=(--executable-path "$PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH")
  fi
  log "  node $PW_MCP_CLI mcp --headless --isolated --port $MCP_PORT --browser chromium --host 127.0.0.1 --allowed-hosts '*' --allow-unrestricted-file-access --config $mcp_config_file${exec_path_arg[*]:+ ${exec_path_arg[*]}}"
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
  devices|device-info|element)
    [[ "${1:-}" == "help" ]] && { print_help; exit 0; } ;;&
  devices)      exec uv run --script "$SSC" devices ;;
  device-info)
    [[ $# -ge 1 ]] || fail "device-info requires a device name, e.g. device-info 'iPhone 15'"
    exec uv run --script "$SSC" device-info "$1" ;;
  install)      exec /install.sh "$@" ;;
  uninstall)    exec /uninstall.sh "$@" ;;
  mcp)          exec node "$PW_MCP_CLI" mcp "$@" ;;
  help|--help|-h) print_help; exit 0 ;;
esac

[[ "$COMMAND" != "screenshot" && "$COMMAND" != "pdf" && "$COMMAND" != "element" ]] && {
  echo "Unknown command: $COMMAND" >&2; usage
}

log "version ${SCREENSHOT_VERSION:-unknown}"

# Defaults
CONVERT_FMT=""
OUT_DIR=""
SCROLL=true
WAIT_TIMEOUT_MS=3000
VIEWPORT="1032x1376"
PAPER_FORMAT="A4"
DISPLAY_HEADER_FOOTER=false
UNCLIP=true
DEVICE_SCALE_FACTOR="2"
USER_AGENT=""
DEVICE=""
IS_MOBILE="false"
HAS_TOUCH="false"

# ssc.py forwarded args (built up as we parse)
SSC_ARGS=()
TARGET=""

URL_PATTERN='^[A-Za-z][A-Za-z0-9+.-]*://'

# Boolean flags are matched explicitly so they never consume the next argument. The generic fallback below also
# refuses to take a URL as a flag value, so the target is accepted in any position, including last.
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      print_help; exit 0 ;;
    --convert)
      [[ $# -lt 2 ]] && fail "--convert requires a format argument"
      CONVERT_FMT="$2"; shift 2 ;;
    --out-dir|-o)
      [[ $# -lt 2 ]] && fail "$1 requires a path argument"
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
    --log-level)
      [[ $# -lt 2 ]] && fail "--log-level requires a level (DEBUG, INFO, WARNING, ERROR, CRITICAL)"
      LOG_LEVEL="$2"; shift 2 ;;
    --headers-footers)
      DISPLAY_HEADER_FOOTER=true; shift ;;
    --no-headers-footers)
      DISPLAY_HEADER_FOOTER=false; shift ;;
    --unclip)
      UNCLIP=true; shift ;;
    --no-unclip)
      UNCLIP=false; shift ;;
    --scroll)
      SCROLL=true; shift ;;
    --no-scroll)
      SCROLL=false; shift ;;
    --dismiss-popups|--no-dismiss-popups)
      SSC_ARGS+=("$1"); shift ;;
    --device-scale-factor)
      [[ $# -lt 2 ]] && fail "--device-scale-factor requires a value"
      DEVICE_SCALE_FACTOR="$2"; shift 2 ;;
    --storage-state)
      [[ $# -lt 2 ]] && fail "--storage-state requires a path"
      SSC_ARGS+=(--storage-state "$2"); shift 2 ;;
    --custom-selector|-c)
      [[ $# -lt 2 ]] && fail "$1 requires a CSS selector"
      SSC_ARGS+=(--custom-selector "$2"); shift 2 ;;
    --hide|-H)
      [[ $# -lt 2 ]] && fail "$1 requires a CSS selector"
      SSC_ARGS+=(--hide "$2"); shift 2 ;;
    --wait-for|-w)
      [[ $# -lt 2 ]] && fail "$1 requires text to wait for"
      SSC_ARGS+=(--wait-for "$2"); shift 2 ;;
    --selector)
      [[ $# -lt 2 ]] && fail "--selector requires a CSS selector"
      SSC_ARGS+=(--selector "$2"); shift 2 ;;
    -s)
      [[ $# -lt 2 ]] && fail "-s requires a value"
      # Same meaning as ssc.py: --selector for element, --storage-state otherwise.
      if [[ "$COMMAND" == "element" ]]; then SSC_ARGS+=(--selector "$2"); else SSC_ARGS+=(--storage-state "$2"); fi
      shift 2 ;;
    --user-agent)
      [[ $# -lt 2 ]] && fail "--user-agent requires a string argument"
      USER_AGENT="$2"; shift 2 ;;
    --device)
      [[ $# -lt 2 ]] && fail "--device requires a device name"
      DEVICE="$2"; shift 2 ;;
    --*)
      # Unknown long flags: pass through to ssc.py, taking the next argument as a value only if it is not
      # another flag and not a URL.
      SSC_ARGS+=("$1")
      if [[ $# -ge 2 && "$2" != -* && ! "$2" =~ $URL_PATTERN ]]; then
        SSC_ARGS+=("$2"); shift
      fi
      shift ;;
    -?*)
      fail "Unknown option: $1 (see --help)" ;;
    *)
      TARGET="$1"; shift ;;
  esac
done

LOG_LEVEL=${LOG_LEVEL:-WARNING}
LOG_LEVEL=${LOG_LEVEL^^}
case "$LOG_LEVEL" in
  WARN) LOG_LEVEL=WARNING ;;
  DEBUG|INFO|WARNING|ERROR|CRITICAL) ;;
  *) fail "Invalid log level '$LOG_LEVEL' (use DEBUG, INFO, WARNING, ERROR or CRITICAL)" ;;
esac
export LOG_LEVEL

[[ -z "$TARGET" ]] && fail "No target specified. Provide a URL or HTML file path."
if [[ "$COMMAND" == "element" ]]; then
  has_selector=false
  for a in "${SSC_ARGS[@]}"; do [[ "$a" == "--selector" ]] && has_selector=true; done
  [[ "$has_selector" == "true" ]] || fail "element requires --selector <css>"
fi

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

if [[ -n "$CONVERT_FMT" && "$COMMAND" == "pdf" ]]; then
  log "warning: --convert is ignored for pdf output"
  CONVERT_FMT=""
fi
FINAL_FILE="$OUT_FILE"
[[ -n "$CONVERT_FMT" ]] && FINAL_FILE="${OUT_FILE%.*}.${CONVERT_FMT}"

log "command:  $COMMAND"
log "target:   $TARGET"
log "output:   $FINAL_FILE"
log "loglevel: $LOG_LEVEL (more detail: --log-level INFO|DEBUG, LOG_LEVEL=INFO|DEBUG, or DEBUG=1 for full trace)"

# Convert --wait-for-timeout ms to --pause ms (ssc.py uses per-scroll-step pause, not total wait)
PAUSE_MS=$(( WAIT_TIMEOUT_MS / 6 ))
[[ "$PAUSE_MS" -lt 200 ]] && PAUSE_MS=200

# Resolve device descriptor before starting MCP so context options are baked in correctly.
if [[ -n "$DEVICE" ]]; then
  log "Resolving device: $DEVICE"
  device_info=$(uv run --script "$SSC" device-info "$DEVICE") || fail "Unknown device: $DEVICE"
  while IFS= read -r line; do
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      VIEWPORT)            VIEWPORT="$value" ;;
      DEVICE_SCALE_FACTOR) DEVICE_SCALE_FACTOR="$value" ;;
      USER_AGENT)          USER_AGENT="$value" ;;
      IS_MOBILE)           IS_MOBILE="$value" ;;
      HAS_TOUCH)           HAS_TOUCH="$value" ;;
    esac
  done <<< "$device_info"
  log "Device resolved: viewport=$VIEWPORT scale=$DEVICE_SCALE_FACTOR isMobile=$IS_MOBILE hasTouch=$HAS_TOUCH"
  SSC_ARGS+=(--device "$DEVICE")
fi

SSC_ARGS+=(--out-dir "$OUT_DIR" --viewport-size "$VIEWPORT")
if [[ "$COMMAND" == "screenshot" || "$COMMAND" == "pdf" ]]; then
  SSC_ARGS+=(--pause "$PAUSE_MS")
  [[ "$SCROLL" == "false" ]] && SSC_ARGS+=(--no-scroll)
fi
[[ "$COMMAND" == "screenshot" ]] && SSC_ARGS+=(--device-scale-factor "$DEVICE_SCALE_FACTOR")
[[ "$COMMAND" == "pdf" ]] && SSC_ARGS+=(--paper-format "$PAPER_FORMAT")
[[ "$COMMAND" == "pdf" && "$DISPLAY_HEADER_FOOTER" == "true" ]] && SSC_ARGS+=(--headers-footers)
if [[ "$COMMAND" == "pdf" ]]; then
  [[ "$UNCLIP" == "true" ]] && SSC_ARGS+=(--unclip) || SSC_ARGS+=(--no-unclip)
fi
[[ "$COMMAND" == "element" ]] && SSC_ARGS+=(--device-scale-factor "$DEVICE_SCALE_FACTOR")
[[ -n "$USER_AGENT" ]] && SSC_ARGS+=(--user-agent "$USER_AGENT")
[[ -n "$CONVERT_FMT" ]] && SSC_ARGS+=(--convert "$CONVERT_FMT")

mcp_cleanup() {
  mcp_stop
  if [[ "$LOG_LEVEL" == "DEBUG" && -s /tmp/mcp-server.log ]]; then
    log "MCP server log (/tmp/mcp-server.log):"
    sed 's/^/    /' /tmp/mcp-server.log >&2
  fi
}
trap mcp_cleanup EXIT
mcp_start

log "Running ssc.py ${COMMAND}..."
log "  uv run --script $SSC $COMMAND ${SSC_ARGS[*]} --url $MCP_URL $RESOLVED_TARGET"
uv run --script "$SSC" "$COMMAND" "${SSC_ARGS[@]}" --url "$MCP_URL" "$RESOLVED_TARGET"

ok "saved ${FINAL_FILE#/}"
