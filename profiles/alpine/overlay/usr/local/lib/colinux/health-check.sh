#!/bin/bash
# health-check.sh — minimal boot health gate for A/B trial confirmation
# Part of CoLinux Lite (v0.5 deliverable: OS-level updates)
#
# Invoked by codex-update-os --bootcheck (typically from first-boot) to decide
# whether a newly-written OS slot should be confirmed or rolled back.
# Returns 0 if the system is healthy enough to confirm the trial, non-zero
# otherwise. codex-update-os handles the rollback.
#
# Override this script by setting COLINUX_HEALTH_SCRIPT (tests/recovery).
set -euo pipefail

PERSIST_DIR="${COLINUX_PERSIST_DIR:-/persist}"
LOGFILE="${PERSIST_DIR}/logs/update-os.log"

log() {
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date)"
    { echo "[$ts] health: $*" >> "$LOGFILE" 2>/dev/null; } || true
}

fail() { log "FAIL $*"; echo "health: FAIL $*" >&2; exit 1; }

# 1. Persistence partition is mounted (data survives reboot).
if command -v mountpoint >/dev/null 2>&1; then
    mountpoint -q "$PERSIST_DIR" 2>/dev/null \
        || fail "persist_not_mounted ($PERSIST_DIR is not a mountpoint)"
else
    # BusyBox has no mountpoint(1); fall back to findmnt/mount output.
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -n "$PERSIST_DIR" >/dev/null 2>&1 \
            || fail "persist_not_mounted (findmnt)"
    else
        mount 2>/dev/null | grep -qE " on ${PERSIST_DIR} " \
            || fail "persist_not_mounted (mount)"
    fi
fi

# 2. The primary appliance interface (codex binary) is present and executable.
[[ -x /usr/local/bin/codex ]] || fail "no_codex_binary (/usr/local/bin/codex missing or not executable)"

# 3. Root filesystem is mounted read-write (a ro root after a trial boot is a
#    strong signal the switch went wrong).
if command -v findmnt >/dev/null 2>&1; then
    opts="$(findmnt -n -o OPTIONS / 2>/dev/null | head -1 || true)"
    case ",${opts}," in
        *,rw,*) : ;;
        *) fail "root_ro (options='$opts')" ;;
    esac
fi

# 4. Init system responded (OpenRC: rc-status; systemd: systemctl is-running).
if command -v rc-status >/dev/null 2>&1; then
    rc-status default >/dev/null 2>&1 || fail "openrc_default_failed"
elif command -v systemctl >/dev/null 2>&1; then
    systemctl is-system-running >/dev/null 2>&1 \
        || systemctl is-system-running 2>/dev/null | grep -qE '^(degraded|starting|running)$' \
        || fail "systemd_not_running"
fi

# 5. Network has at least one non-loopback interface that is up (allows the
#    appliance to reach Codex). Soft check — offline environments still boot.
if command -v ip >/dev/null 2>&1; then
    if ! ip -o link show up 2>/dev/null | grep -qvE '^[0-9]+: lo:'; then
        log "WARN no_up_interfaces (non-fatal)"
    fi
fi

log "OK"
exit 0
