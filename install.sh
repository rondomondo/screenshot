#!/bin/bash
set -euo pipefail

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

URL2CAPTURE_SRC=/usr/local/lib/screenshot/url2capture.sh

examples() {
    printf "\n"
    printf "${BOLD}${CYAN}Install screenshot tools${RESET}\n"
    printf "\n"
    printf "Run the following to install url2pdf and url2image:\n"
    printf "\n"
    printf "  ${BOLD}docker run --rm ghcr.io/rondomondo/screenshot:latest install | sh${RESET}\n"
    printf "\n"
    printf "This installs:\n"
    printf "  ${BOLD}url2pdf${RESET}   -> /usr/local/bin/url2pdf   (or ~/bin/url2pdf)\n"
    printf "  ${BOLD}url2image${RESET} -> /usr/local/bin/url2image (or ~/bin/url2image)\n"
    printf "\n"
    printf "Example usage:\n"
    printf "\n"
    printf "  ${CYAN}url2pdf${RESET} -- save a page as PDF:\n"
    printf "\n"
    printf "    ${BOLD}url2pdf https://en.wikipedia.org/wiki/Special:Random${RESET}\n"
    printf "    ${BOLD}url2pdf https://example.com --convert jpeg${RESET}\n"
    printf "    ${BOLD}url2pdf https://example.com --wait-for-timeout 5000${RESET}\n"
    printf "\n"
    printf "  ${CYAN}url2image${RESET} -- capture a full-page screenshot:\n"
    printf "\n"
    printf "    ${BOLD}url2image https://en.wikipedia.org/wiki/Special:Random${RESET}\n"
    printf "    ${BOLD}url2image https://example.com --convert webp${RESET}\n"
    printf "    ${BOLD}url2image https://example.com --no-scroll${RESET}\n"
    printf "\n"
    printf "Output files are written to ./pdfs/ and ./screenshots/ in the current directory.\n"
    printf "\n"
    printf "Pass DEBUG=1 to see the full docker command before it runs:\n"
    printf "\n"
    printf "  ${BOLD}DEBUG=1 url2pdf https://example.com${RESET}\n"
    printf "\n"
}

# Streaming install: docker run ... install | sh
# Emits a self-contained sh script that installs url2pdf and url2image on the host.
if [[ ! -t 1 ]]; then
    [ -f "$URL2CAPTURE_SRC" ] || { printf "install.sh: missing asset: %s\n" "$URL2CAPTURE_SRC" >&2; exit 1; }

    cat <<'HEADER'
#!/bin/sh
set -e

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

ok()   { printf "${GREEN}ok${RESET}    %s\n" "$1"; }
warn() { printf "${YELLOW}warn${RESET}  %s\n" "$1"; }
info() { printf "${CYAN}info${RESET}  %s\n" "$1"; }

# Install the shared script, then create url2pdf and url2image as symlinks (or copies as fallback).
try_install() {
    local bin_dir

    # Determine install directory: prefer /usr/local/bin, fall back to ~/bin.
    if install -m 755 /dev/null /usr/local/bin/.url2capture_probe 2>/dev/null; then
        rm -f /usr/local/bin/.url2capture_probe
        bin_dir=/usr/local/bin
    elif sudo install -m 755 /dev/null /usr/local/bin/.url2capture_probe 2>/dev/null; then
        sudo rm -f /usr/local/bin/.url2capture_probe
        bin_dir=/usr/local/bin
        USE_SUDO=1
    else
        bin_dir="$HOME/bin"
        mkdir -p "$bin_dir"
        case ":$PATH:" in
            *":$bin_dir:"*) ;;
            *) warn "$bin_dir is not on PATH -- add: export PATH=\"\$HOME/bin:\$PATH\"" ;;
        esac
    fi

    # Install the shared script.
    if [ "${USE_SUDO:-0}" = "1" ]; then
        sudo install -m 755 /tmp/_url2capture_install "$bin_dir/url2capture"
    else
        install -m 755 /tmp/_url2capture_install "$bin_dir/url2capture"
    fi
    ok "$bin_dir/url2capture"

    # Create url2pdf and url2image as symlinks pointing to url2capture.
    for name in url2pdf url2image; do
        target="$bin_dir/$name"
        if [ "${USE_SUDO:-0}" = "1" ]; then
            sudo ln -sf "$bin_dir/url2capture" "$target"
        else
            ln -sf "$bin_dir/url2capture" "$target"
        fi
        ok "$target -> $bin_dir/url2capture"
    done
}

HEADER

    printf '\nprintf "\\n${BOLD}Installing url2pdf and url2image...${RESET}\\n"\n'
    echo "cat > /tmp/_url2capture_install << 'URL2CAPTURE_ASSET_EOF'"
    cat "$URL2CAPTURE_SRC"
    echo "URL2CAPTURE_ASSET_EOF"
    echo "try_install"
    echo "rm -f /tmp/_url2capture_install"
    echo

    cat <<'FOOTER'

printf '\n\033[1mDone.\033[0m\n\n'
printf 'Installed:\n'
printf '  \033[1murl2pdf\033[0m   -> /usr/local/bin/url2pdf   (or ~/bin/url2pdf)\n'
printf '  \033[1murl2image\033[0m -> /usr/local/bin/url2image (or ~/bin/url2image)\n\n'
printf 'Example usage:\n\n'
printf '  \033[0;36murl2pdf\033[0m https://en.wikipedia.org/wiki/Special:Random\n'
printf '  \033[0;36murl2image\033[0m https://en.wikipedia.org/wiki/Special:Random\n\n'
printf 'Output is written to ./pdfs/ and ./screenshots/ in your current directory.\n'
printf 'Pass DEBUG=1 to trace the docker command: DEBUG=1 url2pdf https://example.com\n\n'
FOOTER

    exit 0
fi

# Interactive: print usage instructions
examples
