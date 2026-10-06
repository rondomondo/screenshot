#!/bin/bash
set -euo pipefail

[[ "${DEBUG:-0}" == "1" ]] && set -x

PW_CLI=/app/node_modules/playwright-chromium/cli.js
SCREENSHOTS_DIR=/screenshots
PDFS_DIR=/pdfs

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
  --convert <fmt>          Convert output to fmt after capture (webp, jpeg, gif, ...)
  --out-dir <dir>          Override output directory (default: /screenshots or /pdfs)
  --wait-for-timeout <ms>  Wait before capture (default: 3000)
  --viewport-size <WxH>    Viewport size (default: 1032x1376)
  --full-page              Capture full page (screenshot only, default: on)
  --ignore-https-errors    Ignore TLS errors (default: on)
  --paper-format <fmt>     Paper format for PDF (default: A4)
  Any other --flag value pairs are passed through to playwright.

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
    # Strip scheme, then replace runs of non-alphanumeric chars with a single hyphen
    stem="${target#*://}"
    stem="${stem%%\?*}"   # drop query string
    stem="${stem%%\#*}"   # drop fragment
    # Replace any run of [^a-zA-Z0-9] with a hyphen, then strip leading/trailing hyphens
    stem=$(printf '%s' "$stem" | tr -cs 'a-zA-Z0-9' '-' | sed 's/^-//;s/-$//')
  else
    # Local file: basename without extension
    local base
    base=$(basename "$target")
    stem="${base%.*}"
  fi

  # Lowercase the whole thing
  printf '%s' "${stem,,}"
}

# Parse command
[[ $# -lt 1 ]] && usage
COMMAND="$1"; shift

case "$COMMAND" in
  install)   exec /install.sh "$@" ;;
  uninstall) exec /uninstall.sh "$@" ;;
esac

[[ "$COMMAND" != "screenshot" && "$COMMAND" != "pdf" ]] && {
  echo "Unknown command: $COMMAND" >&2; usage
}

# Defaults
CONVERT_FMT=""
OUT_DIR=""
PW_ARGS=()

# Default playwright flags per command
if [[ "$COMMAND" == "screenshot" ]]; then
  PW_ARGS+=(--wait-for-timeout 3000 --viewport-size '1032,1376' --full-page --ignore-https-errors)
else
  PW_ARGS+=(--wait-for-timeout 3000 --ignore-https-errors --viewport-size '1032,1376' --paper-format 'A4')
fi

# Parse remaining args; strip our own flags, pass the rest through
PASSTHROUGH=()
TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --convert)
      [[ $# -lt 2 ]] && fail "--convert requires a format argument"
      CONVERT_FMT="$2"; shift 2 ;;
    --out-dir)
      [[ $# -lt 2 ]] && fail "--out-dir requires a path argument"
      OUT_DIR="$2"; shift 2 ;;
    # Override known defaults so we don't duplicate them
    --wait-for-timeout|--viewport-size|--paper-format)
      key="$1"; val="$2"; shift 2
      # Remove existing default for this key
      new_args=()
      skip_next=false
      for a in "${PW_ARGS[@]}"; do
        if $skip_next; then skip_next=false; continue; fi
        if [[ "$a" == "$key" ]]; then skip_next=true; continue; fi
        new_args+=("$a")
      done
      PW_ARGS=("${new_args[@]}" "$key" "$val") ;;
    --full-page|--ignore-https-errors)
      # Already in defaults; accept without duplication
      shift ;;
    --no-scroll)
      # Remove --full-page from defaults so playwright captures viewport only
      new_args=()
      for a in "${PW_ARGS[@]}"; do
        [[ "$a" == "--full-page" ]] && continue
        new_args+=("$a")
      done
      PW_ARGS=("${new_args[@]}")
      shift ;;
    --*)
      # Unknown flag: pass through with its value if next arg is not a flag
      PASSTHROUGH+=("$1")
      if [[ $# -ge 2 && "$2" != --* ]]; then
        PASSTHROUGH+=("$2"); shift
      fi
      shift ;;
    *)
      # Non-flag: this is the target
      TARGET="$1"; shift ;;
  esac
done

[[ -z "$TARGET" ]] && fail "No target specified. Provide a URL or HTML file path."

# Resolve local file targets to /html/<file>
RESOLVED_TARGET="$TARGET"
if [[ ! "$TARGET" =~ ^https?:// ]]; then
  # Accept bare filename or full /html/ path
  if [[ "$TARGET" != /* ]]; then
    RESOLVED_TARGET="/html/$TARGET"
  fi
  [[ -f "$RESOLVED_TARGET" ]] || fail "Local file not found: $RESOLVED_TARGET"
  RESOLVED_TARGET="file://$RESOLVED_TARGET"
fi

# Determine output directory and extension
if [[ -z "$OUT_DIR" ]]; then
  if [[ "$COMMAND" == "screenshot" ]]; then
    OUT_DIR="$SCREENSHOTS_DIR"
  else
    OUT_DIR="$PDFS_DIR"
  fi
fi
mkdir -p "$OUT_DIR"

EXT=$([[ "$COMMAND" == "pdf" ]] && echo "pdf" || echo "png")
STEM=$(derive_stem "$TARGET")
OUT_FILE="$OUT_DIR/${STEM}.${EXT}"

log "command:  $COMMAND"
log "target:   $TARGET"
log "output:   $OUT_FILE"

# Run playwright
node "$PW_CLI" "$COMMAND" "${PW_ARGS[@]}" "${PASSTHROUGH[@]}" "$RESOLVED_TARGET" "$OUT_FILE"

ok "saved $OUT_FILE"

# Optional post-conversion
if [[ -n "$CONVERT_FMT" ]]; then
  FINAL_FILE="${OUT_FILE%.*}.${CONVERT_FMT}"
  log "converting $OUT_FILE -> $FINAL_FILE"
  convert "$OUT_FILE" "$FINAL_FILE"
  rm -f "$OUT_FILE"
  ok "converted to $FINAL_FILE"
fi
