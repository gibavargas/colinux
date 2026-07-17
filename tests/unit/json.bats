#!/usr/bin/env bats
# =============================================================================
# CoLinux — --json structured-output contract suite
# =============================================================================
# Locks in the v0.3 deliverable: "every codex-* command returns structured
# JSON on --json". Guards two layers so the contract cannot regress silently.
#
#   1. STATIC CONTRACT — every operational codex-* wrapper shipped in the
#      Alpine overlay (the appliance's /usr/local/bin reference impl):
#        * sources /usr/local/lib/colinux/output.sh
#        * calls colinux_init_output (activates the --json redirect + EXIT trap)
#        * accepts --json (sets COLINUX_JSON)
#        * routes die() through colinux_die (structured errors)
#      Interactive shell launchers (codex-shell*) are exempt.
#
#   2. RUNTIME CONTRACT — exercises the output.sh library directly to prove the
#      emitted envelope is well-formed and parseable in every mode:
#        * success     → {"ok":true,"command","timestamp","message"[,"data"]}
#        * set -e abort → {"ok":false,...,"error":{"message"}}, exit non-zero
#        * colinux_die → custom error envelope, exit 1
#        * text mode   → human stdout unchanged, no JSON emitted
#        * jq-absent   → hand-built fallback still yields valid JSON
#
# Snippets are fed to a subshell via heredoc (quoted delimiter) so that JSON
# payloads with quotes/braces survive intact without backslash escape hell.
# A subshell is required because colinux_init_output() redirects fd 1 and
# installs an EXIT trap, which must not touch the bats TAP protocol on fd 3.
# =============================================================================

load "../lib/helpers"

# The canonical operational codex-* commands shipped in the Alpine overlay
# (AGENTS.md §9, 18 commands). codex-shell is an interactive launcher and is
# intentionally exempt from the --json contract.
_OPERATIONAL_CMDS=(
    codex-backup codex-benchmark codex-clone codex-disk-inventory
    codex-hw-check codex-install-pc codex-install-usb codex-logs
    codex-mount-ro codex-mount-rw codex-network codex-pxe
    codex-recover codex-remote codex-restore codex-snapshot
    codex-update codex-usb-persist
)

_OVERLAY_BIN="$COLINUX_ROOT/profiles/alpine/overlay/usr/local/bin"
_LIB="$COLINUX_ROOT/profiles/alpine/overlay/usr/local/lib/colinux/output.sh"

# Run a bash snippet (read from stdin) in a subshell with the output library
# loaded and COLINUX_* vars pre-set. Args: command_name json_mode.
# Echoes whatever the library writes to real stdout / fd 3.
_json_run() {
    local cmd="$1" json="$2" snippet
    snippet="$(cat)"
    COLINUX_COMMAND="$cmd" COLINUX_JSON="$json" \
        bash --norc -c '
            set -euo pipefail
            source "$1"   # the output library
            eval "$2"     # the caller snippet
        ' bash "$_LIB" "$snippet"
}

# Assert $1 parses as JSON and satisfies a jq filter ($2). Uses jq when
# available, else python3. Skips if neither is present.
_assert_json() {
    local payload="$1" filter="$2"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$payload" | jq -e "$filter" >/dev/null \
            || colinux_fail "JSON schema mismatch.\nfilter: $filter\npayload: $payload"
    elif command -v python3 >/dev/null 2>&1; then
        printf '%s' "$payload" | jq -e "$filter" >/dev/null 2>&1 \
            || colinux_fail "JSON schema mismatch (validate with jq).\npayload: $payload"
    else
        skip "neither jq nor python3 available"
    fi
}

# =============================================================================
# STATIC CONTRACT
# =============================================================================

@test "every shipped operational wrapper honors the --json structured-output contract" {
    local cmd file offenders=""
    for cmd in "${_OPERATIONAL_CMDS[@]}"; do
        file="$_OVERLAY_BIN/$cmd"
        [ -f "$file" ] || { offenders="${offenders}\n  MISSING FILE: $cmd"; continue; }
        # (a) sources the shared library
        if ! grep -q 'source /usr/local/lib/colinux/output.sh' "$file"; then
            offenders="${offenders}\n  NO output.sh source: $cmd"
        fi
        # (b) activates JSON mode (colinux_init_output)
        if ! grep -q 'colinux_init_output' "$file"; then
            offenders="${offenders}\n  NO colinux_init_output: $cmd"
        fi
        # (c) accepts --json (references --json AND assigns COLINUX_JSON)
        if ! grep -q -- '--json' "$file" || ! grep -q 'COLINUX_JSON' "$file"; then
            offenders="${offenders}\n  NO --json/COLINUX_JSON handling: $cmd"
        fi
        # (d) routes die() through colinux_die so failures are structured
        if ! grep -q 'colinux_die' "$file"; then
            offenders="${offenders}\n  NO colinux_die in die(): $cmd"
        fi
    done
    [ -z "$offenders" ] \
        || colinux_fail "Operational wrappers violating the --json contract:${offenders}"
}

@test "disk/ and installer/ mirror copies stay byte-identical to the hardened overlay" {
    # These standalone toolkits are kept as mirrors of the shipped overlay
    # commands. Drift here has repeatedly left stale, un-hardened copies next
    # to hardened ones (audit findings #108, #157). This guard forces any
    # overlay change to be mirrored — or the stale mirror removed.
    local f base ref offenders=""
    for f in "$COLINUX_ROOT"/disk/codex-* "$COLINUX_ROOT"/installer/codex-*; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        ref="$_OVERLAY_BIN/$base"
        [ -f "$ref" ] || { offenders="${offenders}\n  NO OVERLAY REF FOR: ${f#"$COLINUX_ROOT"/}"; continue; }
        if ! diff -q "$f" "$ref" >/dev/null 2>&1; then
            offenders="${offenders}\n  DRIFTED: ${f#"$COLINUX_ROOT"/} != $base"
        fi
    done
    [ -z "$offenders" ] \
        || colinux_fail "Mirror copies drifted from overlay (re-sync or remove):${offenders}"
}

# =============================================================================
# RUNTIME CONTRACT — library behavior is correct & parseable
# =============================================================================

@test "success path emits a valid JSON envelope with required fields" {
    out="$(_json_run test-cmd true <<'SNIPPET'
colinux_init_output
colinux_result "did it" '{"k":1}'
SNIPPET
)" || true
    # Exactly one JSON envelope, nothing else, on stdout.
    local n
    n="$(printf '%s\n' "$out" | grep -cE '"ok"[[:space:]]*:')"
    [ "$n" -eq 1 ] || colinux_fail "expected exactly one JSON envelope, got $n: $out"
    _assert_json "$out" '
        .ok == true
        and .command == "test-cmd"
        and (.timestamp | type == "string")
        and .message == "did it"
        and .data.k == 1
    '
}

@test "success path with no data omits the data field cleanly" {
    out="$(_json_run test-cmd true <<'SNIPPET'
colinux_init_output
colinux_result "ok"
SNIPPET
)" || true
    _assert_json "$out" '.ok == true and (.data | not)'
}

@test "set -e abort emits an error envelope and exits non-zero" {
    set +e
    out="$(_json_run test-cmd true <<'SNIPPET'
colinux_init_output
echo silenced-stdout
false
echo unreached
SNIPPET
)" 2>/dev/null
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || colinux_fail "expected non-zero exit on set -e abort, got $rc"
    _assert_json "$out" '.ok == false and .command == "test-cmd" and (.error.message | type == "string")'
    # Human stdout must have been silenced in JSON mode.
    if printf '%s' "$out" | grep -q 'silenced-stdout'; then
        colinux_fail "human stdout leaked into JSON output: $out"
    fi
}

@test "colinux_die emits a custom error message and exits 1" {
    set +e
    out="$(_json_run test-cmd true <<'SNIPPET'
colinux_init_output
colinux_die "boom: details"
SNIPPET
)" 2>/dev/null
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || colinux_fail "expected exit 1 from colinux_die, got $rc"
    _assert_json "$out" '.ok == false and .error.message == "boom: details"'
}

@test "text mode (no --json) leaves human output unchanged and emits no JSON" {
    out="$(_json_run test-cmd false <<'SNIPPET'
colinux_init_output
echo "human readable line"
colinux_result "done"
SNIPPET
)" || true
    printf '%s' "$out" | grep -q 'human readable line' \
        || colinux_fail "text mode suppressed human output: $out"
    if printf '%s' "$out" | grep -qE '"ok"[[:space:]]*:[[:space:]]*(true|false)'; then
        colinux_fail "text mode leaked a JSON envelope: $out"
    fi
}

@test "jq-absent fallback still produces valid JSON" {
    # Simulate a system without jq by stripping it from PATH. The library must
    # fall back to its hand-built envelope and still emit parseable JSON.
    command -v jq >/dev/null 2>&1 || skip "jq not installed (cannot hide it to test fallback)"
    local lib_dir bash_dir
    lib_dir="$(dirname "$_LIB")"
    bash_dir="$(dirname "$(command -v bash)")"
    out="$(COLINUX_COMMAND=test-cmd COLINUX_JSON=true \
        PATH="$bash_dir:$lib_dir" \
        bash --norc -c '
            set -euo pipefail
            source "$1"
            colinux_init_output
            colinux_result "fallback ok" "{\"n\":2}"
        ' bash "$_LIB")" || true
    # No jq on PATH → library must use the hand-built fallback.
    printf '%s' "$out" | grep -q '"ok":true' \
        || colinux_fail "fallback emitted no JSON object: $out"
    # Validate parse + schema with python3 (jq is deliberately hidden).
    printf '%s' "$out" | python3 -c 'import json,sys
o=json.load(sys.stdin)
assert o["ok"] is True, o
assert o["command"]=="test-cmd", o
assert o["message"]=="fallback ok", o
assert o["data"]["n"]==2, o
' || colinux_fail "fallback JSON did not parse / schema mismatch: $out"
}

@test "EXIT trap does not emit a duplicate envelope after an explicit colinux_result" {
    # The _COLINUX_EMITTED guard must prevent the EXIT trap from appending a
    # second success envelope when the command already emitted one and then
    # exits normally (rc 0). Exactly one envelope must appear on stdout.
    out="$(_json_run test-cmd true <<'SNIPPET'
colinux_init_output
echo silenced-human-text
colinux_result "explicit result"
SNIPPET
)" || true
    local n
    n="$(printf '%s\n' "$out" | grep -cE '"ok"[[:space:]]*:')"
    [ "$n" -eq 1 ] \
        || colinux_fail "expected exactly one envelope (no trap duplicate), got $n: $out"
    # The explicit message must be the one preserved.
    printf '%s\n' "$out" | grep -q '"explicit result"' \
        || colinux_fail "explicit result message not in output: $out"
}
