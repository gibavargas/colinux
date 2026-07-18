#!/bin/bash
# =============================================================================
# colinux/output.sh — Structured-output helpers for codex-* commands
# =============================================================================
# Provides a consistent JSON envelope for `--json` mode while leaving
# human-readable (text) output completely unchanged.
#
# JSON envelope (emitted to stdout, --json mode only):
#
#   success: {"ok":true,"command":"codex-foo","timestamp":"...",
#             "message":"...","data":{...}}
#   error:   {"ok":false,"command":"codex-foo","timestamp":"...",
#             "error":{"message":"..."}}
#
# How it works
# ------------
# In --json mode, colinux_init_output() saves the real stdout on file
# descriptor 3 (`exec 3>&1`) and redirects fd 1 to /dev/null. This silences
# every human-readable `echo`/`printf` the command emits, while leaving
# *pipes* and *command substitutions* (used for command logic) untouched.
# An EXIT trap then guarantees exactly one envelope is emitted on fd 3 —
# success on normal exit, error on failure (including `set -e` aborts).
#
# Usage in a command
# ------------------
#   set -euo pipefail
#   COLINUX_COMMAND="codex-foo"
#   source /usr/local/lib/colinux/output.sh
#   ... mkdir, log_action, etc. ...
#   while [[ $# -gt 0 ]]; do case "$1" in
#       --json) COLINUX_JSON=true; shift ;;
#       ... other options ...
#       --help|-h) usage ;;
#   esac; done
#   colinux_init_output          # activate --json redirect + EXIT-trap guarantee
#   die() { log_action "FATAL $*"; colinux_die "$@"; }
#   ... command logic (unchanged) ...
#   # Optional: emit command-specific data:
#   colinux_result "backed up" '{"file":"x.tar.gz","size":"12M"}'
#
# Variables (all optional; safe defaults provided)
# -----------------------------------------------
#   COLINUX_JSON     "true" to enable JSON mode (else text mode)
#   COLINUX_COMMAND  command name used in the envelope
#   COLINUX_YES      "true" to auto-confirm destructive actions (see colinux_confirm)
# =============================================================================

COLINUX_JSON="${COLINUX_JSON:-false}"
COLINUX_COMMAND="${COLINUX_COMMAND:-colinux}"
COLINUX_YES="${COLINUX_YES:-false}"
_COLINUX_EMITTED=false
_COLINUX_OUTPUT_INSTALLED=false

_colinux_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# Write a line to the structured-output channel: fd 3 when open, else fd 1.
_colinux_out() {
    if { true >&3; } 2>/dev/null; then
        printf '%s\n' "$1" >&3
    else
        printf '%s\n' "$1"
    fi
}

# Build a JSON envelope string (no side effects). Args: ok_bool message [data_json]
_colinux_envelope() {
    local ok="$1" message="$2" data="${3:-}"
    if command -v jq >/dev/null 2>&1; then
        if [[ "$ok" == "true" ]]; then
            if [[ -n "$data" ]]; then
                jq -nc --arg cmd "$COLINUX_COMMAND" --arg ts "$(_colinux_ts)" \
                    --arg msg "$message" --argjson data "$data" \
                    '{ok:true, command:$cmd, timestamp:$ts, message:$msg, data:$data}' 2>/dev/null \
                    || _colinux_envelope_fallback "$ok" "$message" "$data"
            else
                jq -nc --arg cmd "$COLINUX_COMMAND" --arg ts "$(_colinux_ts)" \
                    --arg msg "$message" \
                    '{ok:true, command:$cmd, timestamp:$ts, message:$msg}' 2>/dev/null \
                    || _colinux_envelope_fallback "$ok" "$message" "$data"
            fi
        else
            jq -nc --arg cmd "$COLINUX_COMMAND" --arg ts "$(_colinux_ts)" \
                --arg msg "$message" \
                '{ok:false, command:$cmd, timestamp:$ts, error:{message:$msg}}' 2>/dev/null \
                || _colinux_envelope_fallback "$ok" "$message"
        fi
    else
        _colinux_envelope_fallback "$ok" "$message" "$data"
    fi
}

# Minimal hand-built fallback if jq is unavailable. Escapes " and \ and control
# chars so the message is safe inside a JSON string.
_colinux_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

_colinux_envelope_fallback() {
    local ok="$1" message="$2" data="${3:-}"
    local m ts
    m="$(_colinux_json_escape "$message")"
    ts="$(_colinux_ts)"
    if [[ "$ok" == "true" ]]; then
        if [[ -n "$data" ]]; then
            printf '{"ok":true,"command":"%s","timestamp":"%s","message":"%s","data":%s}' \
                "$COLINUX_COMMAND" "$ts" "$m" "$data"
        else
            printf '{"ok":true,"command":"%s","timestamp":"%s","message":"%s"}' \
                "$COLINUX_COMMAND" "$ts" "$m"
        fi
    else
        printf '{"ok":false,"command":"%s","timestamp":"%s","error":{"message":"%s"}}' \
            "$COLINUX_COMMAND" "$ts" "$m"
    fi
}

# EXIT-trap guarantee: emit exactly one envelope (success on rc 0, error
# otherwise) unless the command already emitted one explicitly.
_colinux_exit_trap() {
    local rc=$?
    if [[ "$COLINUX_JSON" != "true" ]]; then
        return 0
    fi
    if [[ "$_COLINUX_EMITTED" == "true" ]]; then
        return 0
    fi
    if [[ "$rc" -eq 0 ]]; then
        _colinux_out "$(_colinux_envelope true ok)"
    else
        _colinux_out "$(_colinux_envelope false "command failed (exit $rc)")"
    fi
}

# Activate --json mode: silence human stdout and install the EXIT trap.
# Call once, after argument parsing, in the main (non-interactive) shell.
colinux_init_output() {
    if [[ "$COLINUX_JSON" == "true" ]] && [[ "$_COLINUX_OUTPUT_INSTALLED" != "true" ]]; then
        exec 3>&1 1>/dev/null
        _COLINUX_OUTPUT_INSTALLED=true
        trap _colinux_exit_trap EXIT
    fi
}

# Public: emit a success result with optional data. No-op in text mode.
#   colinux_result [message] [data_json]
colinux_result() {
    [[ "$COLINUX_JSON" != "true" ]] && return 0
    local message="${1:-ok}"
    local data="${2:-}"
    _COLINUX_EMITTED=true
    _colinux_out "$(_colinux_envelope true "$message" "$data")"
}

# Public: emit an error and exit 1. In text mode, prints to stderr like die().
colinux_die() {
    local message="$*"
    if [[ "$COLINUX_JSON" == "true" ]]; then
        _COLINUX_EMITTED=true
        _colinux_out "$(_colinux_envelope false "$message")"
        exit 1
    fi
    echo "ERROR: $message" >&2
    exit 1
}

# Public: interactive confirmation for destructive actions.
#   colinux_confirm "Type RESTORE to confirm:" "RESTORE"  || die "aborted"
#   colinux_confirm "Continue? [y/N]"
# In --json mode, returns 0 only when COLINUX_YES=true; otherwise 1 (the caller
# should die with a "pass --yes" message). In text mode, prompts the user and
# accepts y/yes, or an exact match if an expected value is given.
colinux_confirm() {
    local prompt="$1" expected="${2:-}"
    if [[ "$COLINUX_JSON" == "true" ]]; then
        [[ "$COLINUX_YES" == "true" ]] && return 0
        return 1
    fi
    local resp=""
    read -rp "$prompt " resp || resp=""
    if [[ -n "$expected" ]]; then
        [[ "$resp" == "$expected" ]]
        return $?
    fi
    case "${resp,,}" in
        y|yes) return 0 ;;
        *) return 1 ;;
    esac
}
