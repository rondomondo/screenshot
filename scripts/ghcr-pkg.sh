#!/usr/bin/env bash
#
# ghcr-pkg.sh - list and delete GitHub Container Registry package versions via gh.
#
# Requires: gh, jq, and a CLASSIC PAT (fine-grained tokens cannot access Packages)
# with read:packages (list) and read:packages + delete:packages (delete).

set -euo pipefail

# --- defaults (override via env or flags) ------------------------------------
OWNER="${GHCR_OWNER:-rondomondo}"
PACKAGE="${GHCR_PACKAGE:-screenshot}"
TOKEN_VAR="${GHCR_TOKEN_VAR:-GITHUB_TOKEN_PACKAGES}"   # NAME of the env var holding the token
OWNER_TYPE="${GHCR_OWNER_TYPE:-auto}"                   # auto | user | org
UNTAGGED_ONLY=false
OLDER_THAN_DAYS=0
DRY_RUN=false
ASSUME_YES=false
DELETE_IDS=()  # explicit version IDs to delete

# --- helpers -----------------------------------------------------------------
prog="$(basename "$0")"

usage() {
  cat <<EOF
Usage: $prog <command> [options]

Commands:
  list              List package versions (id, created, tags)
  delete            Delete package versions (all, or filtered)
  delete-package    Delete the entire package in one call

Options:
  -o OWNER          GitHub user/org that owns the package   (default: $OWNER)
  -p PACKAGE        Package name                            (default: $PACKAGE)
  -e TOKEN_VAR      Env var NAME holding the token          (default: $TOKEN_VAR)
  -t TYPE           Owner type: auto|user|org               (default: $OWNER_TYPE)
  -i ID             delete: delete a specific version ID (repeatable)
  -u                delete/list: only untagged versions
  -d DAYS           delete/list: only versions older than DAYS days
  -n                Dry run: show what would be deleted, change nothing
  -y                Skip the confirmation prompt
  -h                Show this help

Environment overrides: GHCR_OWNER, GHCR_PACKAGE, GHCR_TOKEN_VAR, GHCR_OWNER_TYPE

Examples:
  $prog list
  $prog delete -n                 # dry run, all versions
  $prog delete -u -d 30 -y        # untagged and older than 30 days, no prompt
  $prog delete -i 12345678 -y     # delete a specific version by ID
  $prog delete-package -o myorg -p myimage
EOF
}

log()  { printf '%s\n' "$*" >&2; }
die()  { log "error: $*"; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH"; }

confirm() {
  $ASSUME_YES && return 0
  [[ -t 0 ]] || die "not a TTY and -y not given; refusing to delete"
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# --- argument parsing --------------------------------------------------------
[[ $# -ge 1 ]] || { usage; exit 1; }
case "$1" in
  -h|--help) usage; exit 0 ;;
  list|delete|delete-package) CMD="$1"; shift ;;
  *) usage; die "unknown command: $1" ;;
esac

while getopts ":o:p:e:t:d:i:unyh" opt; do
  case "$opt" in
    o) OWNER="$OPTARG" ;;
    p) PACKAGE="$OPTARG" ;;
    e) TOKEN_VAR="$OPTARG" ;;
    t) OWNER_TYPE="$OPTARG" ;;
    d) OLDER_THAN_DAYS="$OPTARG" ;;
    i) DELETE_IDS+=("$OPTARG") ;;
    u) UNTAGGED_ONLY=true ;;
    n) DRY_RUN=true ;;
    y) ASSUME_YES=true ;;
    h) usage; exit 0 ;;
    :) die "option -$OPTARG requires an argument" ;;
    \?) die "unknown option: -$OPTARG" ;;
  esac
done

[[ "$OLDER_THAN_DAYS" =~ ^[0-9]+$ ]] || die "-d must be a non-negative integer"
[[ "$OWNER_TYPE" =~ ^(auto|user|org)$ ]] || die "-t must be auto, user or org"

# --- preflight ---------------------------------------------------------------
require gh
require jq

token="${!TOKEN_VAR:-}"
[[ -n "$token" ]] || die "env var $TOKEN_VAR is empty or unset"
export GH_TOKEN="$token"

resolve_owner_path() {
  case "$OWNER_TYPE" in
    user) echo "users/$OWNER" ;;
    org)  echo "orgs/$OWNER" ;;
    auto)
      local t
      t="$(gh api "/users/$OWNER" --jq .type 2>/dev/null)" \
        || die "cannot resolve owner '$OWNER' (bad name or token?)"
      [[ "$t" == "Organization" ]] && echo "orgs/$OWNER" || echo "users/$OWNER"
      ;;
  esac
}

BASE="/$(resolve_owner_path)/packages/container/$PACKAGE"

# Emits one compact JSON object per version, with filters applied.
fetch_versions() {
  gh api --paginate "$BASE/versions?per_page=100" \
    | jq -c \
        --argjson untagged "$UNTAGGED_ONLY" \
        --argjson days "$OLDER_THAN_DAYS" '
      .[]
      | {id, created_at, tags: (.metadata.container.tags // [])}
      | select(($untagged | not) or (.tags | length == 0))
      | select($days == 0 or ((.created_at | fromdateiso8601) < (now - $days * 86400)))
    '
}

# --- commands ----------------------------------------------------------------
cmd_list() {
  printf 'ID\tCREATED\tTAGS\n'
  fetch_versions | jq -r '[.id, .created_at, (.tags | join(","))] | @tsv'
}

cmd_delete() {
  local ok=0 fail=0 id count

  if [[ "${#DELETE_IDS[@]}" -gt 0 ]]; then
    count="${#DELETE_IDS[@]}"
    log "targeted $count explicit version ID(s) of ghcr.io/$OWNER/$PACKAGE:"
    for id in "${DELETE_IDS[@]}"; do log "  $id"; done
    if $DRY_RUN; then log "dry run: nothing deleted"; return 0; fi
    confirm "Permanently delete $count version(s)?" || { log "aborted"; return 1; }
    for id in "${DELETE_IDS[@]}"; do
      if gh api -X DELETE "$BASE/versions/$id" >/dev/null 2>&1; then
        ok=$((ok + 1)); log "deleted $id"
      else
        fail=$((fail + 1)); log "FAILED  $id"
      fi
    done
    log "done: $ok deleted, $fail failed"
    if [[ "$fail" -gt 0 ]]; then
      log "hint: GitHub may refuse to delete the last remaining version; use '$prog delete-package'"
      return 1
    fi
    return 0
  fi

  # Collect ids up front so deletes don't disturb pagination.
  local versions
  versions="$(fetch_versions)"
  if [[ -z "$versions" ]]; then count=0; else count="$(printf '%s\n' "$versions" | grep -c .)"; fi

  if [[ "$count" -eq 0 ]]; then
    log "no matching versions for $OWNER/$PACKAGE"
    return 0
  fi

  log "matched $count version(s) of ghcr.io/$OWNER/$PACKAGE:"
  printf '%s\n' "$versions" \
    | jq -r '"  \(.id)\t\(.created_at)\t\(.tags | join(","))"' >&2

  if $DRY_RUN; then
    log "dry run: nothing deleted"
    return 0
  fi

  confirm "Permanently delete $count version(s)?" || { log "aborted"; return 1; }

  while read -r id; do
    if gh api -X DELETE "$BASE/versions/$id" >/dev/null 2>&1; then
      ok=$((ok + 1))
      log "deleted $id"
    else
      fail=$((fail + 1))
      log "FAILED  $id"
    fi
  done < <(printf '%s\n' "$versions" | jq -r '.id')

  log "done: $ok deleted, $fail failed"
  if [[ "$fail" -gt 0 ]]; then
    log "hint: GitHub may refuse to delete the last remaining version; use '$prog delete-package'"
    return 1
  fi
}

cmd_delete_package() {
  log "target: ghcr.io/$OWNER/$PACKAGE (entire package, all versions)"
  if $DRY_RUN; then
    log "dry run: nothing deleted"
    return 0
  fi
  confirm "Permanently delete the whole package?" || { log "aborted"; return 1; }
  gh api -X DELETE "$BASE" >/dev/null
  log "package deleted (restorable for 30 days via POST $BASE/restore)"
}

case "$CMD" in
  list)           cmd_list ;;
  delete)         cmd_delete ;;
  delete-package) cmd_delete_package ;;
esac
