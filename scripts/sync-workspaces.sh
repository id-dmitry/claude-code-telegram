#!/usr/bin/env bash
# =============================================================================
# sync-workspaces.sh — clone/pull claude-code-telegram workspaces at startup.
#
# Reads projects.yaml, iterates enabled entries, clones missing repos, or
# fetches+rebase-pulls existing ones. Graceful on 404 so a not-yet-created
# repo (e.g. albaniall-wordpress) never blocks the bot from starting.
#
# Env:
#   PROJECTS_CONFIG_PATH  — path to projects.yaml (default /config/projects.yaml)
#   APPROVED_DIRECTORY    — parent dir of clones (default /projects)
#   DATA_DIR              — log target parent (default /data)
#   GITHUB_OWNER          — owner of workspace repos (default id-dmitry)
#   GITHUB_APP_TOKEN      — optional; used for HTTPS clone auth
#   GIT_SSH_COMMAND       — optional; enables SSH-based clone as fallback
#   SYNC_GIT_TIMEOUT      — per-git-op timeout in seconds (default 90)
#
# Exit: always 0 on reachable config. Non-zero only on unrecoverable env errors.
# =============================================================================

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

readonly SCRIPT_NAME="sync-workspaces"
readonly CONFIG_PATH="${PROJECTS_CONFIG_PATH:-/config/projects.yaml}"
readonly PROJECTS_ROOT="${APPROVED_DIRECTORY:-/projects}"
readonly DATA_DIR="${DATA_DIR:-/data}"
readonly LOG_FILE="${DATA_DIR}/sync.log"
readonly OWNER="${GITHUB_OWNER:-id-dmitry}"
readonly GIT_TIMEOUT="${SYNC_GIT_TIMEOUT:-90}"

# --- logging ----------------------------------------------------------------

_log() {
    # $1=level, $2..=message
    local level="$1"
    shift
    local ts
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf '%s [%s] [%s] %s\n' "$ts" "$SCRIPT_NAME" "$level" "$*" | tee -a "$LOG_FILE" >&2
}

log_info() { _log INFO "$@"; }
log_warn() { _log WARN "$@"; }
log_err()  { _log ERROR "$@"; }

# --- init -------------------------------------------------------------------

mkdir -p "$DATA_DIR" "$PROJECTS_ROOT" || {
    printf 'FATAL: cannot create %s or %s\n' "$DATA_DIR" "$PROJECTS_ROOT" >&2
    exit 2
}
: > "$LOG_FILE" || true  # allow truncation failure on ro-fs; tee will still try

if [[ ! -r "$CONFIG_PATH" ]]; then
    log_warn "config not found or unreadable at $CONFIG_PATH — nothing to sync"
    exit 0
fi

# --- repo-name derivation ---------------------------------------------------
# slug → repo. Slug format: <prefix>-<branch>, branch ∈ {prod,dev}.
#   estate-*  → estateall-bot
#   vitali-*  → vitali-assistant
#   wp-*      → albaniall-wordpress
# Any other prefix → repo = "<prefix>" literally (future-proof fallback).

slug_to_repo() {
    local slug="$1"
    local prefix="${slug%-*}"
    case "$prefix" in
        estate) printf 'estateall-bot\n' ;;
        vitali) printf 'vitali-assistant\n' ;;
        wp)     printf 'albaniall-wordpress\n' ;;
        *)      printf '%s\n' "$prefix" ;;
    esac
}

slug_to_branch() {
    local slug="$1"
    printf '%s\n' "${slug##*-}"
}

# --- URL building -----------------------------------------------------------
# Prefer tokenized HTTPS when GITHUB_APP_TOKEN is set; otherwise anonymous HTTPS.
# SSH path is triggered only via GIT_SSH_COMMAND env — for private repos without a token.

repo_url() {
    local repo="$1"
    if [[ -n "${GITHUB_APP_TOKEN:-}" ]]; then
        printf 'https://x-access-token:%s@github.com/%s/%s.git\n' \
            "$GITHUB_APP_TOKEN" "$OWNER" "$repo"
    elif [[ -n "${GIT_SSH_COMMAND:-}" ]]; then
        printf 'git@github.com:%s/%s.git\n' "$OWNER" "$repo"
    else
        printf 'https://github.com/%s/%s.git\n' "$OWNER" "$repo"
    fi
}

# --- single-project sync ---------------------------------------------------

sync_one() {
    local slug="$1" target="$2"
    local repo branch url
    repo="$(slug_to_repo "$slug")"
    branch="$(slug_to_branch "$slug")"
    url="$(repo_url "$repo")"

    log_info "sync slug=$slug → repo=$OWNER/$repo branch=$branch path=$target"

    if [[ -d "$target/.git" ]]; then
        if ! timeout "${GIT_TIMEOUT}s" git -C "$target" fetch --all --prune --quiet; then
            log_warn "fetch failed for $slug ($OWNER/$repo) — skipping pull"
            return 0
        fi
        if ! timeout "${GIT_TIMEOUT}s" git -C "$target" pull --rebase --autostash --quiet; then
            log_warn "pull --rebase failed for $slug — workspace may need manual intervention"
            return 0
        fi
        log_info "updated $slug"
    else
        if [[ -e "$target" && ! -d "$target" ]]; then
            log_warn "$target exists but is not a directory — skipping $slug"
            return 0
        fi
        mkdir -p "$(dirname -- "$target")"
        if ! timeout "${GIT_TIMEOUT}s" git clone --branch "$branch" --single-branch \
                --depth 50 -- "$url" "$target" 2>>"$LOG_FILE"; then
            log_warn "clone failed for $slug ($OWNER/$repo:$branch) — repo may not exist or branch missing; skipping"
            # Leftover partial dir is removed so next run retries cleanly.
            [[ -d "$target" && ! -d "$target/.git" ]] && rm -rf -- "$target"
            return 0
        fi
        log_info "cloned $slug"
    fi
}

# --- config iteration via python (PyYAML already in image) ------------------
# Emit one line per enabled project: "<slug>\t<path>"

iter_enabled_projects() {
    python3 - "$CONFIG_PATH" <<'PY'
import sys, yaml
cfg_path = sys.argv[1]
with open(cfg_path, "r", encoding="utf-8") as fh:
    data = yaml.safe_load(fh) or {}
for proj in data.get("projects", []) or []:
    if not proj.get("enabled", False):
        continue
    slug = (proj.get("slug") or "").strip()
    path = (proj.get("path") or "").strip()
    if not slug or not path:
        continue
    print(f"{slug}\t{path}")
PY
}

# --- main -------------------------------------------------------------------

main() {
    log_info "starting sync — config=$CONFIG_PATH root=$PROJECTS_ROOT owner=$OWNER"

    local line slug target
    local total=0 ok=0
    # Process substitution keeps counters in the parent shell (no subshell).
    while IFS=$'\t' read -r slug target; do
        [[ -z "$slug" || -z "$target" ]] && continue
        total=$((total + 1))
        if sync_one "$slug" "$target"; then
            ok=$((ok + 1))
        fi
    done < <(iter_enabled_projects)

    log_info "sync complete — $ok/$total workspaces processed without fatal errors"
    return 0
}

main "$@"
