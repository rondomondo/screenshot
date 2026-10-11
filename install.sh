#!/bin/bash
set -euo pipefail

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

IMAGE_REGISTRY="${IMAGE_REGISTRY:-ghcr.io}"
IMAGE_REPO="${IMAGE_REPO:-rondomondo/screenshot}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
IMAGE="${IMAGE_REGISTRY}/${IMAGE_REPO}:${IMAGE_TAG}"

# EXAMPLE_URL=https://en.wikipedia.org/wiki/Special:Random

EXAMPLE_URL="${EXAMPLE_URL:-https://jax-ml.github.io/scaling-book/index}"

URL2CAPTURE_SRC=/usr/local/lib/screenshot/url2capture.sh

examples() {
    printf "\n"
    printf "${BOLD}${CYAN}Install screenshot tools${RESET}\n"
    printf "\n"
    printf "Run the following to install url2pdf and url2image:\n"
    printf "\n"
    printf "  ${BOLD}docker run --rm %s install | sh${RESET}\n" "$IMAGE"
    printf "\n"
    printf "This installs:\n"
    printf "  ${BOLD}url2pdf${RESET}   -> /usr/local/bin/url2pdf   (or ~/.local/bin/url2pdf)\n"
    printf "  ${BOLD}url2image${RESET} -> /usr/local/bin/url2image (or ~/.local/bin/url2image)\n"
    printf "\n"
    printf "Example usage:\n"
    printf "\n"
    printf "  ${CYAN}url2pdf${RESET} -- save a page as PDF:\n"
    printf "\n"
    printf "    ${BOLD}url2pdf %s${RESET}\n" "$EXAMPLE_URL"
    printf "    ${BOLD}url2pdf %s --convert jpeg${RESET}\n" "$EXAMPLE_URL"
    printf "    ${BOLD}url2pdf %s --wait-for-timeout 5000${RESET}\n" "$EXAMPLE_URL"
    printf "\n"
    printf "  ${CYAN}url2image${RESET} -- capture a full-page screenshot:\n"
    printf "\n"
    printf "    ${BOLD}url2image %s${RESET}\n" "$EXAMPLE_URL"
    printf "    ${BOLD}url2image %s --convert webp${RESET}\n" "$EXAMPLE_URL"
    printf "    ${BOLD}url2image %s --no-scroll${RESET}\n" "$EXAMPLE_URL"
    printf "\n"
    printf "Output files are written to ./pdfs/ and ./screenshots/ in the current directory.\n"
    printf "\n"
    printf "Pass DEBUG=1 to see the full docker command before it runs:\n"
    printf "\n"
    printf "  ${BOLD}DEBUG=1 url2pdf %s${RESET}\n" "$EXAMPLE_URL"
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

add_to_path_if_needed() {
    local dir="$1"
    local rcfile

    case ":$PATH:" in
        *":$dir:"*) return 0 ;;
    esac

    case "${SHELL##*/}" in
        zsh)  rcfile="$HOME/.zshrc" ;;
        bash) rcfile="$HOME/.bashrc" ;;
        fish) rcfile="$HOME/.config/fish/config.fish" ;;
        *)    rcfile="" ;;
    esac

    if [ -n "$rcfile" ]; then
        if ! grep -qF "$dir" "$rcfile" 2>/dev/null; then
            printf '\nexport PATH="%s:$PATH"\n' "$dir" >> "$rcfile"
            ok "added $dir to PATH in $rcfile"
            warn "restart your shell or run: source $rcfile"
        else
            info "$dir already referenced in $rcfile -- skipping"
        fi
    else
        warn "$dir is not on PATH -- add: export PATH=\"$dir:\$PATH\""
    fi
}

# Install the shared script, then create url2pdf and url2image as symlinks.
try_install() {
    local bin_dir

    # Prefer /usr/local/bin (with or without sudo), fall back to ~/.local/bin.
    if install -m 755 /dev/null /usr/local/bin/.url2capture_probe 2>/dev/null; then
        rm -f /usr/local/bin/.url2capture_probe
        bin_dir=/usr/local/bin
    elif sudo install -m 755 /dev/null /usr/local/bin/.url2capture_probe 2>/dev/null; then
        sudo rm -f /usr/local/bin/.url2capture_probe
        bin_dir=/usr/local/bin
        USE_SUDO=1
    else
        bin_dir="$HOME/.local/bin"
        mkdir -p "$bin_dir"
        add_to_path_if_needed "$bin_dir"
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

    printf "\nprintf '\\n\\033[1mDone.\\033[0m\\n\\n'\n"
    printf "printf 'Installed:\\n'\n"
    printf "printf '  \\033[1murl2pdf\\033[0m   -> /usr/local/bin/url2pdf   (or ~/.local/bin/url2pdf)\\n'\n"
    printf "printf '  \\033[1murl2image\\033[0m -> /usr/local/bin/url2image (or ~/.local/bin/url2image)\\n\\n'\n"
    printf "printf 'Example usage:\\n\\n'\n"
    printf "printf '  \\033[0;36murl2pdf\\033[0m %s\\n'\n" "$EXAMPLE_URL"
    printf "printf '  \\033[0;36murl2image\\033[0m %s\\n\\n'\n" "$EXAMPLE_URL"
    printf "printf 'Output is written to ./pdfs/ and ./screenshots/ in your current directory.\\n'\n"
    printf "printf 'Pass DEBUG=1 to trace the docker command: DEBUG=1 url2pdf %s\\n\\n'\n" "$EXAMPLE_URL"

    exit 0
fi

# Interactive: print usage instructions
examples
