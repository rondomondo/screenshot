#!/bin/sh
set -e

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RESET='\033[0m'

IMAGE_TAG="${IMAGE_TAG:-latest}"
IMAGE="ghcr.io/rondomondo/screenshot:${IMAGE_TAG}"

# Dispatch based on the name this script was invoked as.
INVOKED_AS="$(basename "$0")"
case "$INVOKED_AS" in
    url2pdf)   COMMAND=pdf        VERB="saving"    ;;
    url2image) COMMAND=screenshot VERB="capturing" ;;
    *)
        printf "Unknown command name: %s. Install as url2pdf or url2image.\n" "$INVOKED_AS" >&2
        exit 1
        ;;
esac

usage() {
    case "$COMMAND" in
        pdf)
            printf "${BOLD}Usage:${RESET} url2pdf <url-or-file> [options]\n" >&2
            printf "\nSave a web page as PDF.\n" >&2
            printf "\n${BOLD}Options:${RESET}\n" >&2
            printf "  --convert <fmt>         Convert output after capture (e.g. jpeg)\n" >&2
            printf "  --wait-for-timeout <ms> Wait before capture (default: 3000)\n" >&2
            printf "  --viewport-size <WxH>   Viewport dimensions (default: 1032x1376)\n" >&2
            printf "  --paper-format <fmt>    Paper format (default: A4)\n" >&2
            printf "  --ignore-https-errors   Ignore TLS errors\n" >&2
            printf "\n${BOLD}Examples:${RESET}\n" >&2
            printf "  url2pdf https://en.wikipedia.org/wiki/Special:Random\n" >&2
            printf "  url2pdf https://example.com --convert jpeg\n" >&2
            ;;
        screenshot)
            printf "${BOLD}Usage:${RESET} url2image <url-or-file> [options]\n" >&2
            printf "\nCapture a full-page screenshot of a web page.\n" >&2
            printf "\n${BOLD}Options:${RESET}\n" >&2
            printf "  --convert <fmt>         Convert output after capture (e.g. webp, jpeg)\n" >&2
            printf "  --wait-for-timeout <ms> Wait before capture (default: 3000)\n" >&2
            printf "  --viewport-size <WxH>   Viewport dimensions (default: 1032x1376)\n" >&2
            printf "  --no-scroll             Capture viewport only (no full-page scroll)\n" >&2
            printf "  --ignore-https-errors   Ignore TLS errors\n" >&2
            printf "\n${BOLD}Examples:${RESET}\n" >&2
            printf "  url2image https://en.wikipedia.org/wiki/Special:Random\n" >&2
            printf "  url2image https://example.com --convert webp\n" >&2
            ;;
    esac
    printf "  -h, --help              Show this help\n" >&2
    printf "\nOutput is written to ./pdfs/ or ./screenshots/ in the current directory.\n" >&2
    printf "\n${BOLD}Environment:${RESET}\n" >&2
    printf "  IMAGE_TAG               Docker image tag to use (default: latest)\n" >&2
    printf "                          e.g. IMAGE_TAG=0.0.21 url2pdf https://example.com\n" >&2
    exit 1
}

[ $# -eq 0 ] && usage

# Scan args for the target (first non-flag argument); flags may appear before or after.
TARGET=""
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage ;;
        --*) ;;
        *) TARGET="$arg"; break ;;
    esac
done

[ -z "$TARGET" ] && { printf "Error: no URL or file target supplied.\n" >&2; usage; }

CWD="$(pwd)"
mkdir -p "${CWD}/pdfs" "${CWD}/screenshots"

# Only mount html/ when the target looks like a local file path.
case "$TARGET" in
    http://*|https://*) HTML_MOUNT="" ;;
    *) mkdir -p "${CWD}/html"; HTML_MOUNT="-v ${CWD}/html:/html:ro" ;;
esac

printf "${CYAN}%s${RESET} %s ${BOLD}%s${RESET}\n" "$INVOKED_AS" "$VERB" "$TARGET" >&2

DEBUG_FLAG=""
[ "${DEBUG:-0}" = "1" ] && DEBUG_FLAG="-e DEBUG=1"

if [ "${DEBUG:-0}" = "1" ]; then
    printf "${CYAN}debug${RESET}  docker run --rm %s -v %s/pdfs:/pdfs -v %s/screenshots:/screenshots %s %s %s %s\n" \
        "$DEBUG_FLAG" "$CWD" "$CWD" "$HTML_MOUNT" "$IMAGE" "$COMMAND" "$*" >&2
fi

# shellcheck disable=SC2086
exec docker run --rm \
    $DEBUG_FLAG \
    -v "${CWD}/pdfs:/pdfs" \
    -v "${CWD}/screenshots:/screenshots" \
    $HTML_MOUNT \
    "$IMAGE" \
    "$COMMAND" "$@"
