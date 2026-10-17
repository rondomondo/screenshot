#!/bin/sh
set -e

BOLD='\033[1m'
CYAN='\033[0;36m'
RESET='\033[0m'

IMAGE_REGISTRY="${IMAGE_REGISTRY:-ghcr.io}"
IMAGE_REPO="${IMAGE_REPO:-rondomondo/screenshot}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
IMAGE="${IMAGE_REGISTRY}/${IMAGE_REPO}:${IMAGE_TAG}"

EXAMPLE_URL="${EXAMPLE_URL:-https://jax-ml.github.io/scaling-book/index}"

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
            printf "       url2pdf devices\n" >&2
            printf "       url2pdf device-info '<device name>'\n" >&2
            printf "\nSave a web page as PDF.\n" >&2
            printf "\n${BOLD}Commands:${RESET}\n" >&2
            printf "  devices                 List devices usable with --device\n" >&2
            printf "  device-info <name>      Show the descriptor for one device\n" >&2
            printf "\n${BOLD}Options:${RESET}\n" >&2
            printf "  --wait-for-timeout <ms> Wait before capture (default: 3000)\n" >&2
            printf "  --wait-for <text>       Wait for this text to appear before capture\n" >&2
            printf "  --viewport-size <WxH>   Viewport dimensions (default: 1032x1376)\n" >&2
            printf "  --paper-format <fmt>    Paper format (default: A4)\n" >&2
            printf "  --headers-footers       Include browser-generated header and footer\n" >&2
            printf "  --no-headers-footers    Omit header and footer (default)\n" >&2
            printf "  --unclip, --no-unclip   Free fixed-height scroll containers (default: on)\n" >&2
            printf "  --no-scroll             Skip the pre-render scroll that triggers lazy loading\n" >&2
            printf "  --hide, -H <css>        Element to hide before render (repeatable)\n" >&2
            printf "  --device <name>         Emulate a device (overrides viewport and user-agent)\n" >&2
            printf "  --user-agent <string>   Browser user-agent string\n" >&2
            printf "  --dismiss-popups, --no-dismiss-popups\n" >&2
            printf "                          Toggle cookie and popup dismissal (default: on)\n" >&2
            printf "  --custom-selector, -c <css>\n" >&2
            printf "                          Extra popup selector to click (repeatable)\n" >&2
            printf "  --storage-state, -s <file>\n" >&2
            printf "                          Playwright storageState JSON (cookies, localStorage)\n" >&2
            printf "\n${BOLD}Examples:${RESET}\n" >&2
            printf "  url2pdf ${EXAMPLE_URL}\n" >&2
            printf "  url2pdf https://en.wikipedia.org/wiki/Special:Random --paper-format Letter\n" >&2
            printf "  url2pdf https://en.wikipedia.org/wiki/Dash_Crofts --hide '.infobox'\n" >&2
            ;;
        screenshot)
            printf "${BOLD}Usage:${RESET} url2image <url-or-file> [options]\n" >&2
            printf "       url2image element --selector <css> <url-or-file> [options]\n" >&2
            printf "       url2image devices\n" >&2
            printf "       url2image device-info '<device name>'\n" >&2
            printf "\nCapture a full-page screenshot of a web page, or just one element of it.\n" >&2
            printf "\n${BOLD}Commands:${RESET}\n" >&2
            printf "  element                 Capture only the first element matching --selector\n" >&2
            printf "  devices                 List devices usable with --device\n" >&2
            printf "  device-info <name>      Show the descriptor for one device\n" >&2
            printf "\n${BOLD}Options:${RESET}\n" >&2
            printf "  --convert <fmt>         Convert output after capture (e.g. webp, jpeg)\n" >&2
            printf "  --wait-for-timeout <ms> Wait before capture (default: 3000)\n" >&2
            printf "  --wait-for <text>       Wait for this text to appear before capture\n" >&2
            printf "  --viewport-size <WxH>   Viewport dimensions (default: 1032x1376)\n" >&2
            printf "  --device-scale-factor <n>\n" >&2
            printf "                          Device pixel ratio (default: 2)\n" >&2
            printf "  --no-scroll             Capture viewport only (no full-page scroll)\n" >&2
            printf "  --device <name>         Emulate a device (overrides viewport, scale, user-agent)\n" >&2
            printf "  --user-agent <string>   Browser user-agent string\n" >&2
            printf "  --dismiss-popups, --no-dismiss-popups\n" >&2
            printf "                          Toggle cookie and popup dismissal (default: on, off for element)\n" >&2
            printf "  --custom-selector, -c <css>\n" >&2
            printf "                          Extra popup selector to click (repeatable)\n" >&2
            printf "  --storage-state <file>  Playwright storageState JSON (cookies, localStorage)\n" >&2
            printf "\n${BOLD}Element options:${RESET}\n" >&2
            printf "  --selector, -s <css>    Element to capture (required for element)\n" >&2
            printf "  --hide, -H <css>        Element to hide before capture (repeatable)\n" >&2
            printf "\n${BOLD}Examples:${RESET}\n" >&2
            printf "  url2image ${EXAMPLE_URL}\n" >&2
            printf "  url2image https://en.wikipedia.org/wiki/Special:Random --convert webp\n" >&2
            printf "  url2image https://en.wikipedia.org/wiki/Special:Random --device 'iPhone 15'\n" >&2
            printf "  url2image element --selector '.infobox' https://en.wikipedia.org/wiki/Dash_Crofts\n" >&2
            ;;
    esac
    printf "  -h, --help, help        Show this help (also: devices help, device-info help, element help)\n" >&2
    printf "\nTarget: a URL, or a local HTML file inside ./html (given as a path relative to ./html).\n" >&2
    printf "Output is written to ./pdfs/ or ./screenshots/ in the current directory.\n" >&2
    printf "\n${BOLD}Environment:${RESET}\n" >&2
    printf "  IMAGE_TAG               Docker image tag (default: latest)\n" >&2
    printf "  IMAGE_REGISTRY          Registry host (default: ghcr.io)\n" >&2
    printf "  IMAGE_REPO              Image repository (default: rondomondo/screenshot)\n" >&2
    printf "                          e.g. IMAGE_TAG=latest url2pdf ${EXAMPLE_URL}\n" >&2
    printf "  LOG_LEVEL               DEBUG, INFO, WARNING (default), ERROR or CRITICAL; also --log-level <level>\n" >&2
    printf "  DEBUG=1                 Print the docker command, set LOG_LEVEL=DEBUG and trace the container shell\n" >&2
    exit "${1:-1}"
}

[ $# -eq 0 ] && usage 1
[ "$1" = "help" ] && usage 0

command -v docker >/dev/null 2>&1 || { printf "Error: docker is required but was not found in PATH.\n" >&2; exit 1; }

# Subcommand that must come first: devices, device-info <name>, element.
case "$1" in
    devices|device-info)
        SUBCOMMAND="$1"; shift
        case "$1" in -h|--help|help) usage 0 ;; esac
        if [ "$SUBCOMMAND" = "device-info" ] && [ $# -ne 1 ]; then
            printf "Error: device-info takes exactly one device name, e.g. device-info 'iPhone 15'.\n" >&2
            exit 1
        fi
        if [ "$SUBCOMMAND" = "devices" ] && [ $# -ne 0 ]; then
            printf "Error: devices takes no arguments.\n" >&2
            exit 1
        fi
        TTY_FLAG=""
        [ -t 1 ] && TTY_FLAG="-t"
        # shellcheck disable=SC2086
        exec docker run --rm $TTY_FLAG "$IMAGE" "$SUBCOMMAND" "$@"
        ;;
    element)
        if [ "$COMMAND" != "screenshot" ]; then
            printf "Error: element produces an image; use url2image element ...\n" >&2
            exit 1
        fi
        COMMAND=element; VERB="capturing element of"; shift
        [ "$1" = "help" ] && usage 0
        [ $# -eq 0 ] && usage 1
        ;;
esac

# Walk the arguments once to find the target and rewrite host paths. Flags that take a value are skipped so a
# value such as '.infobox' or 'webp' is never mistaken for the target. The loop rotates "$@" so quoting survives.
TARGET=""
STORAGE_MOUNT=""
EXPECT_VALUE=""
ARG_COUNT=$#
while [ "$ARG_COUNT" -gt 0 ]; do
    arg="$1"; shift; ARG_COUNT=$((ARG_COUNT - 1))
    if [ -n "$EXPECT_VALUE" ]; then
        if [ "$EXPECT_VALUE" = "storage" ]; then
            if [ ! -f "$arg" ]; then
                printf "Error: storage state file not found: %s\n" "$arg" >&2
                exit 1
            fi
            STORAGE_DIR="$(cd "$(dirname "$arg")" && pwd)"
            STORAGE_MOUNT="${STORAGE_DIR}:/storage:ro"
            arg="/storage/$(basename "$arg")"
        fi
        EXPECT_VALUE=""
        set -- "$@" "$arg"
        continue
    fi
    case "$arg" in
        -h|--help) usage 0 ;;
        --storage-state) EXPECT_VALUE=storage ;;
        -s)
            if [ "$COMMAND" = "element" ]; then EXPECT_VALUE=plain; else EXPECT_VALUE=storage; fi ;;
        --convert|--out-dir|-o|--wait-for-timeout|--wait-for|-w|--viewport-size|--paper-format|--device-scale-factor|--custom-selector|-c|--hide|-H|--selector|--user-agent|--device|--log-level)
            EXPECT_VALUE=plain ;;
        -*) ;;
        *) [ -z "$TARGET" ] && TARGET="$arg" ;;
    esac
    set -- "$@" "$arg"
done

if [ -n "$EXPECT_VALUE" ]; then
    printf "Error: the last option is missing its value.\n" >&2
    usage 1
fi

[ -z "$TARGET" ] && { printf "Error: no URL or file target supplied.\n" >&2; usage 1; }

if [ "$COMMAND" = "element" ]; then
    case " $* " in
        *" --selector "*|*" -s "*) ;;
        *) printf "Error: element requires --selector <css>.\n" >&2; usage 1 ;;
    esac
fi

CWD="$(pwd)"
mkdir -p "${CWD}/pdfs" "${CWD}/screenshots"

printf "${CYAN}%s${RESET} %s ${BOLD}%s${RESET}\n" "$INVOKED_AS" "$VERB" "$TARGET" >&2

# Build the docker command in the positional parameters (prepending) so paths containing spaces stay intact.
set -- "$IMAGE" "$COMMAND" "$@"
[ -n "$STORAGE_MOUNT" ] && set -- -v "$STORAGE_MOUNT" "$@"

# Only mount html/ when the target looks like a local file path.
case "$TARGET" in
    http://*|https://*) ;;
    *) mkdir -p "${CWD}/html"; set -- -v "${CWD}/html:/html:ro" "$@" ;;
esac

set -- -v "${CWD}/pdfs:/pdfs" -v "${CWD}/screenshots:/screenshots" "$@"
case "$(printf '%s' "${DEBUG:-0}" | tr 'A-Z' 'a-z')" in 1|true|yes|on) DEBUG_ON=1 ;; *) DEBUG_ON=0 ;; esac
[ "$DEBUG_ON" = "1" ] && set -- -e DEBUG=1 "$@"
[ -n "${LOG_LEVEL:-}" ] && set -- -e "LOG_LEVEL=${LOG_LEVEL}" "$@"
set -- run --rm "$@"

[ "$DEBUG_ON" = "1" ] && printf "${CYAN}debug${RESET}  docker %s\n" "$*" >&2

exec docker "$@"
