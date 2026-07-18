#!/bin/bash
# =============================================================================
# colinux/logging.sh — Standardized logging + rotation for CoLinux commands
# =============================================================================
# Establishes the CoLinux logging standard (ROADMAP v0.3 "Logging
# standardization"). Two concerns, one small self-contained library:
#
# 1. A standard log line format (appended to /persist/logs/<category>.log):
#
#       [YYYY-MM-DD HH:MM:SS UTC] [LEVEL] message
#
#    where LEVEL ∈ {INFO, WARN, ERROR, DEBUG}. Existing wrapper scripts keep
#    their own log_action() helpers; this library is the canonical API for
#    new code and for the rotation command below.
#
# 2. A BusyBox-safe rotation policy (exercised by codex-log-rotate):
#    * Size-based: when a log exceeds COLINUX_LOG_MAX_KB (default 5120 KiB =
#      5 MiB) the active log is renamed to <name>.1 and gzipped; existing
#      archives shift up by one; archives beyond COLINUX_LOG_KEEP (default 7)
#      are deleted.
#    * Age-based: archives (<log>.*.gz) older than COLINUX_LOG_MAX_AGE_DAYS
#      (default 30) are pruned on every rotate pass.
#
# The library depends only on bash 4+ and coreutils/BusyBox (date, gzip, find,
# mv, rm, wc). It does NOT depend on colinux/output.sh, so any script —
# including build-time and first-boot code — can source it.
#
# Usage:
#   source /usr/local/lib/colinux/logging.sh
#   colinux_log_init backup                  # → /persist/logs/backup.log
#   colinux_log_info  "started backup"       # → [ts UTC] [INFO] started backup
#   colinux_log_warn  "low disk"
#   colinux_log_error "backup failed: $msg"
#   colinux_log_rotate                       # rotate this category if oversized
#   colinux_log_rotate_all                   # rotate every /persist/logs/*.log
#
# All functions are namespaced with the colinux_ prefix so they never collide
# with a wrapper's existing log()/log_action()/die() helpers.
# =============================================================================

# ── Defaults (override via environment BEFORE sourcing) ─────────────────────
COLINUX_LOG_DIR="${COLINUX_LOG_DIR:-/persist/logs}"
COLINUX_LOG_MAX_KB="${COLINUX_LOG_MAX_KB:-5120}"     # rotate when log ≥ 5 MiB
COLINUX_LOG_KEEP="${COLINUX_LOG_KEEP:-7}"            # rotated archives to keep
COLINUX_LOG_MAX_AGE_DAYS="${COLINUX_LOG_MAX_AGE_DAYS:-30}"
COLINUX_LOG_CATEGORY="${COLINUX_LOG_CATEGORY:-colinux}"
# COLINUX_LOG_FILE is set by colinux_log_init; empty default below is fine.
COLINUX_LOG_FILE="${COLINUX_LOG_FILE:-}"

# ── Internal helpers ────────────────────────────────────────────────────────

# RFC3339-ish UTC timestamp. `date -u` is supported by both GNU and BusyBox.
_colinux_log_ts() {
    date -u '+%Y-%m-%d %H:%M:%S UTC'
}

# Ensure the log directory exists. Best-effort: never fail the caller (logging
# must not crash a privileged operation because /persist is read-only).
# Uses a defensive default so the function is safe under `set -u` even if a
# caller sourced the library via a temporary prefix assignment
# (`COLINUX_LOG_DIR=/x source lib`) whose value reverts after source returns.
_colinux_log_ensure_dir() {
    local dir="${COLINUX_LOG_DIR:-/persist/logs}"
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || true
}

# ── Public API ──────────────────────────────────────────────────────────────

# Initialize logging for a category. Sets COLINUX_LOG_CATEGORY and
# COLINUX_LOG_FILE="$COLINUX_LOG_DIR/<category>.log". Safe to call repeatedly.
# Usage: colinux_log_init [category]
colinux_log_init() {
    COLINUX_LOG_CATEGORY="${1:-$COLINUX_LOG_CATEGORY}"
    _colinux_log_ensure_dir
    COLINUX_LOG_FILE="$COLINUX_LOG_DIR/${COLINUX_LOG_CATEGORY}.log"
}

# Write one structured log line: [YYYY-MM-DD HH:MM:SS UTC] [LEVEL] message
# Usage: colinux_log <LEVEL> <message...>
# Never returns non-zero (logging must not abort the caller).
colinux_log() {
    local level="$1"; shift
    local msg="$*"
    _colinux_log_ensure_dir
    local dir="${COLINUX_LOG_DIR:-/persist/logs}"
    local file="$COLINUX_LOG_FILE"
    [ -n "$file" ] || file="$dir/${COLINUX_LOG_CATEGORY:-colinux}.log"
    printf '[%s] [%s] %s\n' "$(_colinux_log_ts)" "$level" "$msg" \
        >> "$file" 2>/dev/null || true
}

colinux_log_info()  { colinux_log INFO  "$*"; }
colinux_log_warn()  { colinux_log WARN  "$*"; }
colinux_log_error() { colinux_log ERROR "$*"; }
colinux_log_debug() { colinux_log DEBUG "$*"; }

# Rotate a single log file when it exceeds the size threshold, then age-prune
# its rotated archives. A no-op when the file is absent or undersized — safe
# and idempotent to re-run any number of times.
#
# The active log is moved to <name>.1 and gzipped. We deliberately do NOT
# recreate an empty active file: the next append (>>) recreates it with the
# writer's ownership, avoiding root↔codex ownership drift when rotation runs
# as root (e.g. via the system crontab).
#
# Usage: colinux_log_rotate [file] [max_kb] [keep] [max_age_days]
colinux_log_rotate() {
    local file="${1:-$COLINUX_LOG_FILE}"
    local max_kb="${2:-$COLINUX_LOG_MAX_KB}"
    local keep="${3:-$COLINUX_LOG_KEEP}"
    local max_age_days="${4:-$COLINUX_LOG_MAX_AGE_DAYS}"

    # Validate/normalize numerics; fall back to defaults on garbage input so a
    # bad arg can never make rotation destructive.
    case "$max_kb" in (*[!0-9]*) max_kb="$COLINUX_LOG_MAX_KB";; esac
    case "$keep"   in (*[!0-9]*) keep="$COLINUX_LOG_KEEP";; esac
    case "$max_age_days" in (*[!0-9]*) max_age_days="$COLINUX_LOG_MAX_AGE_DAYS";; esac
    [ "$max_kb" -gt 0 ] 2>/dev/null || max_kb="$COLINUX_LOG_MAX_KB"
    [ "$keep"  -ge 0 ] 2>/dev/null || keep="$COLINUX_LOG_KEEP"
    [ "$max_age_days" -ge 0 ] 2>/dev/null || max_age_days="$COLINUX_LOG_MAX_AGE_DAYS"

    [ -n "$file" ] || return 0
    local dir base
    dir="$(dirname "$file")"
    base="$(basename "$file")"
    [ -d "$dir" ] || return 0

    # 1. Age-prune rotated archives older than max_age_days (runs every pass,
    #    even when the active log is undersized — this is how old archives get
    #    cleaned up for low-volume logs).
    if [ "$max_age_days" -gt 0 ]; then
        find "$dir" -maxdepth 1 -name "${base}.*.gz" -type f \
            -mtime "+${max_age_days}" -delete 2>/dev/null || true
    fi

    # 2. Size gate.
    [ -f "$file" ] || return 0
    local bytes kb
    bytes="$(wc -c < "$file" 2>/dev/null | tr -dc '0-9')"
    [ -n "$bytes" ] || return 0
    kb=$(( bytes / 1024 ))
    [ "$kb" -ge "$max_kb" ] || return 0

    # 3. Shift existing archives up: drop the oldest beyond `keep`, then
    #    .(N-1).gz → .N.gz, ..., .1.gz → .2.gz. Iterate from the top down so
    #    each destination slot is freed before it is written.
    [ "$keep" -gt 0 ] || return 0   # keep=0 would discard history entirely
    local i
    i="$keep"
    while [ "$i" -gt 0 ]; do
        if [ "$i" -eq "$keep" ]; then
            [ -f "$dir/${base}.${i}.gz" ] && rm -f "$dir/${base}.${i}.gz" 2>/dev/null || true
        else
            [ -f "$dir/${base}.${i}.gz" ] && mv -f "$dir/${base}.${i}.gz" "$dir/${base}.$((i + 1)).gz" 2>/dev/null || true
        fi
        i=$(( i - 1 ))
    done

    # 4. Rotate the active log → .1 and compress. Failures here are non-fatal
    #    (a read-only /persist or a busy file just means we skip this round).
    mv -f "$file" "$dir/${base}.1" 2>/dev/null || return 0
    gzip -f "$dir/${base}.1" 2>/dev/null || true
}

# Rotate every *.log under COLINUX_LOG_DIR. Usage:
#   colinux_log_rotate_all [max_kb] [keep] [max_age_days]
colinux_log_rotate_all() {
    local max_kb="${1:-$COLINUX_LOG_MAX_KB}"
    local keep="${2:-$COLINUX_LOG_KEEP}"
    local max_age_days="${3:-$COLINUX_LOG_MAX_AGE_DAYS}"
    local dir="${COLINUX_LOG_DIR:-/persist/logs}"
    [ -d "$dir" ] || return 0
    local f
    # find(1) in a process substitution keeps set -e / pipefail from aborting
    # the loop if a file vanishes mid-iteration.
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        colinux_log_rotate "$f" "$max_kb" "$keep" "$max_age_days"
    done < <(find "$dir" -maxdepth 1 -name '*.log' -type f 2>/dev/null)
}
