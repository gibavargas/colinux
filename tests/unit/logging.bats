#!/usr/bin/env bats
# =============================================================================
# CoLinux — Logging standardization suite (ROADMAP v0.3)
# =============================================================================
# Guards the "Logging standardization" deliverable:
#
#   * the shared logging library exists and parses cleanly
#   * colinux_log writes the canonical format
#     [YYYY-MM-DD HH:MM:SS UTC] [LEVEL] message
#   * colinux_log_rotate produces a gzipped .1 archive for oversized logs
#   * rotation is idempotent (undersize → no-op; re-runs are safe)
#   * rotation respects the --keep cap (no unbounded archive growth)
#   * colinux_log_rotate_all covers every *.log in the directory
#   * the codex-log-rotate CLI parses, exposes --help, and rotates end-to-end
#
# The library is exercised in a throwaway temp dir so tests never touch the
# real /persist/logs. Each test sources the library fresh (bats forks a new
# shell per @test), so env overrides are isolated automatically.
# =============================================================================

load "../lib/helpers"

LOGGING_SH="$COLINUX_ROOT/profiles/alpine/overlay/usr/local/lib/colinux/logging.sh"
ROTATE_CMD="$COLINUX_ROOT/profiles/alpine/overlay/usr/local/bin/codex-log-rotate"
ROTATE_CMD_COMPAT="$COLINUX_ROOT/profiles/debian-compat/overlay/usr/local/bin/codex-log-rotate"

setup() {
    TEST_LOG_DIR="$(mktemp -d)"
    export TEST_LOG_DIR
}

teardown() {
    [ -n "${TEST_LOG_DIR:-}" ] && rm -rf "$TEST_LOG_DIR"
}

# Source the library with COLINUX_LOG_DIR pointed at the temp dir and the given
# defaults. Usage: _load_lib [max_kb] [keep] [max_age_days]
_load_lib() {
    export COLINUX_LOG_DIR="$TEST_LOG_DIR"
    export COLINUX_LOG_MAX_KB="${1:-1}"
    export COLINUX_LOG_KEEP="${2:-3}"
    export COLINUX_LOG_MAX_AGE_DAYS="${3:-1}"
    # shellcheck disable=SC1090
    source "$LOGGING_SH"
}

# -----------------------------------------------------------------------------
# Library existence & syntax
# -----------------------------------------------------------------------------

@test "logging.sh exists and is syntactically valid" {
    [ -f "$LOGGING_SH" ]
    bash -n "$LOGGING_SH"
}

@test "logging.sh declares a bash shebang on line 1" {
    head -n1 "$LOGGING_SH" | grep -qE '^#! */usr/bin/env bash|^#! */bin/bash'
}

# -----------------------------------------------------------------------------
# Standard log line format
# -----------------------------------------------------------------------------

@test "colinux_log emits INFO WARN ERROR DEBUG with the right level tag" {
    _load_lib
    colinux_log_init levels
    colinux_log_info  "an info"
    colinux_log_warn  "a warn"
    colinux_log_error "an error"
    colinux_log_debug "a debug"
    grep -qE '\[INFO\] an info'      "$TEST_LOG_DIR/levels.log"
    grep -qE '\[WARN\] a warn'       "$TEST_LOG_DIR/levels.log"
    grep -qE '\[ERROR\] an error'    "$TEST_LOG_DIR/levels.log"
    grep -qE '\[DEBUG\] a debug'     "$TEST_LOG_DIR/levels.log"
    # Timestamp shape: [YYYY-MM-DD HH:MM:SS UTC]
    head -n1 "$TEST_LOG_DIR/levels.log" \
        | grep -qE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} UTC\] '
}

@test "colinux_log never returns non-zero even when the log dir is unwritable" {
    # Point at a path that cannot be created; colinux_log must still return 0.
    run bash -c '
        set -euo pipefail
        COLINUX_LOG_DIR=/proc/1/notwritable source "'"$LOGGING_SH"'"
        colinux_log_info "should not crash"
        echo survived
    '
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "survived"
}

# -----------------------------------------------------------------------------
# Rotation: oversized log -> .1.gz
# -----------------------------------------------------------------------------

@test "colinux_log_rotate rotates an oversized log into a valid .1.gz" {
    _load_lib
    # Fill big.log past 1 KiB, then rotate.
    for i in $(seq 1 200); do
        echo "padding line $i needs enough bytes to grow past 1KiB here"
    done > "$TEST_LOG_DIR/big.log"
    [ "$(wc -c < "$TEST_LOG_DIR/big.log")" -ge 1024 ]   # precondition
    colinux_log_rotate "$TEST_LOG_DIR/big.log" 1 3 1
    # active oversize log moved away (no longer non-empty)
    [ ! -s "$TEST_LOG_DIR/big.log" ]
    # gzipped archive created and valid
    [ -f "$TEST_LOG_DIR/big.log.1.gz" ]
    gzip -t "$TEST_LOG_DIR/big.log.1.gz"
}

@test "rotation is idempotent: undersize log is a no-op, re-runs are safe" {
    _load_lib
    echo "small line" > "$TEST_LOG_DIR/idem.log"
    colinux_log_rotate "$TEST_LOG_DIR/idem.log" 1 3 1
    colinux_log_rotate "$TEST_LOG_DIR/idem.log" 1 3 1
    [ -f "$TEST_LOG_DIR/idem.log" ]
    [ ! -f "$TEST_LOG_DIR/idem.log.1.gz" ]
}

@test "rotation respects the keep cap (archives never exceed keep)" {
    _load_lib
    r=0
    while [ "$r" -lt 5 ]; do
        r=$((r + 1))
        for j in $(seq 1 200); do
            echo "round $r line $j padding padding padding"
        done > "$TEST_LOG_DIR/keep.log"
        colinux_log_rotate "$TEST_LOG_DIR/keep.log" 1 3 1
    done
    n=$(find "$TEST_LOG_DIR" -maxdepth 1 -name 'keep.log.*.gz' | wc -l)
    [ "$n" -le 3 ]
}

@test "colinux_log_rotate_all rotates every .log in the directory" {
    _load_lib
    for n in alpha beta gamma; do
        for i in $(seq 1 200); do echo "$n padding $i enough bytes here"; done \
            > "$TEST_LOG_DIR/$n.log"
    done
    colinux_log_rotate_all 1 3 1
    [ -f "$TEST_LOG_DIR/alpha.log.1.gz" ]
    [ -f "$TEST_LOG_DIR/beta.log.1.gz" ]
    [ -f "$TEST_LOG_DIR/gamma.log.1.gz" ]
}

@test "rotation with a missing file is a safe no-op" {
    _load_lib
    colinux_log_rotate "$TEST_LOG_DIR/does-not-exist.log" 1 3 1
}

@test "rotation tolerates garbage numeric args without being destructive" {
    _load_lib
    echo "data" > "$TEST_LOG_DIR/g.log"
    colinux_log_rotate "$TEST_LOG_DIR/g.log" "abc" "x" "nope"
    [ -f "$TEST_LOG_DIR/g.log" ]
}

# -----------------------------------------------------------------------------
# codex-log-rotate CLI contract
# -----------------------------------------------------------------------------

@test "codex-log-rotate alpine copy is syntactically valid" {
    [ -f "$ROTATE_CMD" ]
    bash -n "$ROTATE_CMD"
}

@test "codex-log-rotate debian-compat copy mirrors the alpine copy" {
    [ -f "$ROTATE_CMD" ]
    [ -f "$ROTATE_CMD_COMPAT" ]
    if ! diff -q "$ROTATE_CMD" "$ROTATE_CMD_COMPAT" >/dev/null; then
        colinux_fail "alpine and debian-compat codex-log-rotate differ"
    fi
}

@test "codex-log-rotate documents help flag and defines a die helper" {
    grep -Eq -- 'help' "$ROTATE_CMD"
    grep -Eq 'die[[:space:]]*\(\)' "$ROTATE_CMD"
}

@test "codex-log-rotate sources the logging and output libraries" {
    grep -q 'colinux/logging.sh' "$ROTATE_CMD"
    grep -q 'colinux/output.sh' "$ROTATE_CMD"
}

@test "codex-log-rotate end-to-end rotates logs via COLINUX_LOG_DIR override" {
    # Expose the library at the runtime path the wrapper expects, run into a
    # temp dir, then remove the link. Skipped if we cannot stage the link.
    if [ ! -w /usr/local/lib ] && ! command -v sudo >/dev/null 2>&1; then
        skip "cannot stage library at /usr/local/lib/colinux"
    fi
    mkdir -p /usr/local/lib/colinux 2>/dev/null || sudo mkdir -p /usr/local/lib/colinux
    if [ -w /usr/local/lib/colinux ]; then
        ln -sf "$LOGGING_SH" /usr/local/lib/colinux/logging.sh
    else
        sudo ln -sf "$LOGGING_SH" /usr/local/lib/colinux/logging.sh
    fi

    for n in one two; do
        for i in $(seq 1 200); do echo "$n padding $i"; done > "$TEST_LOG_DIR/$n.log"
    done

    run env COLINUX_LOG_DIR="$TEST_LOG_DIR" "$ROTATE_CMD" --max-kb 1 --quiet
    status=$?
    sudo rm -f /usr/local/lib/colinux/logging.sh 2>/dev/null || rm -f /usr/local/lib/colinux/logging.sh

    [ "$status" -eq 0 ]
    [ -f "$TEST_LOG_DIR/one.log.1.gz" ]
    [ -f "$TEST_LOG_DIR/two.log.1.gz" ]
}
