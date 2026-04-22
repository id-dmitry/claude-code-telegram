#!/usr/bin/env bash
# =============================================================================
# entrypoint.sh — container startup wrapper.
#
# 1. Run one-shot workspace sync (timeout 120s; failures are non-fatal).
# 2. exec tini + requested CMD (defaults to claude-telegram-bot from poetry
#    scripts), so tini is PID 1 and handles SIGTERM/SIGINT cleanly.
#
# Env:
#   SYNC_TIMEOUT  — overall timeout for sync step in seconds (default 120)
#   SKIP_SYNC     — set to "1" to skip sync entirely (useful in dev)
# =============================================================================

set -Eeuo pipefail

readonly SYNC_SCRIPT="/app/scripts/sync-workspaces.sh"
readonly SYNC_TIMEOUT="${SYNC_TIMEOUT:-120}"

log() { printf '[entrypoint] %s\n' "$*" >&2; }

# --- sync step --------------------------------------------------------------

if [[ "${SKIP_SYNC:-0}" == "1" ]]; then
    log "SKIP_SYNC=1 — skipping workspace sync"
elif [[ -x "$SYNC_SCRIPT" ]]; then
    log "running workspace sync (timeout ${SYNC_TIMEOUT}s)"
    # `|| true` keeps bot startup independent of sync outcome.
    # Sync script already swallows per-project failures; this guards only
    # catastrophic timeouts / interpreter errors.
    timeout --preserve-status "${SYNC_TIMEOUT}s" "$SYNC_SCRIPT" || {
        rc=$?
        log "workspace sync exited with code $rc — continuing to bot startup"
    }
else
    log "WARN: sync script $SYNC_SCRIPT not executable — skipping"
fi

# --- bot exec ---------------------------------------------------------------

# If the container was invoked with a CMD override, honor it. Otherwise run
# the default poetry script entry. In both cases tini becomes PID 1 via exec.
if [[ "$#" -gt 0 ]]; then
    log "exec tini -- $*"
    exec /usr/bin/tini -- "$@"
else
    log "exec tini -- claude-telegram-bot"
    exec /usr/bin/tini -- claude-telegram-bot
fi
