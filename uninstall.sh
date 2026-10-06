#!/bin/bash
set -euo pipefail

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

# Streaming uninstall: docker run ... uninstall | sh
# Emits a self-contained sh script that removes url2pdf, url2image, and url2capture from the host.
if [[ ! -t 1 ]]; then
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

try_remove_bin() {
    local name="$1"
    local removed=0
    for dir in /usr/local/bin "$HOME/bin"; do
        local target="$dir/$name"
        [ -f "$target" ] || [ -L "$target" ] || continue
        if rm -f "$target" 2>/dev/null; then
            ok "removed $target"
            removed=1
        elif sudo rm -f "$target" 2>/dev/null; then
            ok "removed $target (via sudo)"
            removed=1
        else
            warn "could not remove $target (permission denied)"
        fi
    done
    [ "$removed" -eq 0 ] && info "$name not found in /usr/local/bin or ~/bin -- nothing to remove"
}

HEADER

    for name in url2pdf url2image url2capture; do
        echo "printf '\\n${BOLD}Uninstalling ${name}...${RESET}\\n'"
        echo "try_remove_bin $name"
        echo
    done

    cat <<'FOOTER'

printf '\n\033[1mDone.\033[0m\n'
printf '  url2pdf, url2image, and url2capture removed from PATH\n\n'
FOOTER

    exit 0
fi

# Interactive: print usage instructions
printf "\n"
printf "${BOLD}${CYAN}Uninstall screenshot tools${RESET}\n"
printf "\n"
printf "Run the following to remove url2pdf and url2image:\n"
printf "\n"
printf "  ${BOLD}docker run --rm ghcr.io/rondomondo/screenshot:latest uninstall | sh${RESET}\n"
printf "\n"
printf "This removes:\n"
printf "  ${BOLD}url2pdf${RESET}     from /usr/local/bin or ~/bin\n"
printf "  ${BOLD}url2image${RESET}   from /usr/local/bin or ~/bin\n"
printf "  ${BOLD}url2capture${RESET} from /usr/local/bin or ~/bin\n"
printf "\n"
