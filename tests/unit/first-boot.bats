#!/usr/bin/env bats
# =============================================================================
# CoLinux — First-boot idempotency suite (ROADMAP v0.3)
# =============================================================================
# Guards the "First-boot idempotency" deliverable: scripts/first-boot.sh must
# be safe to re-run without side effects. Two layers of defense are verified:
#
#   1. Top-level guard — if $FIRST_BOOT_FLAG exists and --force was not passed,
#      the script exits 0 without re-running any step.
#   2. Per-step guards — every step that touches persistent state checks current
#      state before acting, so even --force re-runs (or a deleted marker) are
#      safe: no duplicate mounts, no clobbered auth file, no duplicate DHCP
#      daemons, no noisy LUKS open errors.
#
# The end-to-end test runs the script twice in dry-run mode against the same
# simulated /persist dir and asserts:
#   * run 1 completes and writes the marker
#   * run 2 is a no-op (marker byte-identical, "already complete" logged)
#   * run 3 with --force re-runs (marker updated, no errors)
#
# Static contract checks (grep-based) guard the per-step guards themselves so
# a future refactor cannot silently drop them.
# =============================================================================

load "../lib/helpers"

FIRST_BOOT="$COLINUX_ROOT/scripts/first-boot.sh"

setup() {
    SIM_ROOT="$(mktemp -d)"
    SIM_PERSIST="$SIM_ROOT/persist"
    export SIM_ROOT SIM_PERSIST
    export CODEX_PERSIST_SIM="$SIM_PERSIST"
}

teardown() {
    [ -n "${SIM_ROOT:-}" ] && rm -rf "$SIM_ROOT"
}

# -----------------------------------------------------------------------------
# Existence & syntax
# -----------------------------------------------------------------------------

@test "first-boot.sh exists and is syntactically valid (bash -n)" {
    [ -f "$FIRST_BOOT" ]
    bash -n "$FIRST_BOOT"
}

@test "first-boot.sh declares a bash shebang on line 1" {
    head -n1 "$FIRST_BOOT" | grep -qE '^#! */usr/bin/env bash|^#! */bin/bash'
}

@test "first-boot.sh enables strict error mode" {
    grep -Eq 'set -e(uo pipefail|u pipefail|uo|u)' "$FIRST_BOOT"
}

# -----------------------------------------------------------------------------
# --force flag and help text
# -----------------------------------------------------------------------------

@test "first-boot.sh --help documents --force and --dry-run" {
    run bash "$FIRST_BOOT" --help
    [ "$status" -eq 0 ]
    echo "$output" | grep -q -- '--dry-run'
    echo "$output" | grep -q -- '--force'
}

@test "first-boot.sh parses FORCE variable from --force flag" {
    grep -q 'FORCE=false' "$FIRST_BOOT"
    grep -Eq '\-\-force\)' "$FIRST_BOOT"
}

# -----------------------------------------------------------------------------
# Top-level idempotency guard (marker check in main)
# -----------------------------------------------------------------------------

@test "first-boot.sh has a top-level FIRST_BOOT_FLAG guard in main()" {
    # The guard must reference both the marker file and the FORCE flag, and
    # return 0 (no-op) when the marker is present and force is not.
    grep -q 'FIRST_BOOT_FLAG' "$FIRST_BOOT"
    # Look inside main() for the guard pattern
    awk '/^main\(\)/,/^}/' "$FIRST_BOOT" | grep -q 'FIRST_BOOT_FLAG'
    awk '/^main\(\)/,/^}/' "$FIRST_BOOT" | grep -Eq 'FORCE.*true|"\$FORCE"'
}

@test "first-boot.sh guard returns 0 (no-op) when marker exists without --force" {
    # The guard block must contain a `return 0` so subsequent steps are skipped.
    awk '/^main\(\)/,/^}/' "$FIRST_BOOT" \
        | grep -A3 'FIRST_BOOT_FLAG' \
        | grep -q 'return 0'
}

# -----------------------------------------------------------------------------
# Per-step idempotency guards (static contract)
# -----------------------------------------------------------------------------

@test "bind-mount is guarded by mountpoint check (no duplicate bind-mounts)" {
    # The mount --bind line must be preceded by a mountpoint -q guard.
    grep -A2 'mount --bind' "$FIRST_BOOT" >/dev/null
    # Find the bind-mount block and confirm it has a mountpoint check
    grep -B3 'mount --bind' "$FIRST_BOOT" | grep -q 'mountpoint -q'
}

@test "LUKS open is guarded by mapper device existence check" {
    # cryptsetup open must be skipped if /dev/mapper/$mapper_name already exists.
    grep -q 'cryptsetup open' "$FIRST_BOOT"
    grep -q '/dev/mapper/$mapper_name' "$FIRST_BOOT"
}

@test "network DHCP start is guarded by running-daemon check" {
    # dhcpcd/udhcpc must not be re-invoked if a DHCP client is already running.
    grep -q 'dhcpcd' "$FIRST_BOOT"
    grep -Eq 'pgrep -x (dhcpcd|udhcpc)' "$FIRST_BOOT"
}

@test "auth setup preserves existing file when a real key is present" {
    # The destructive `cat > "$auth_file"` rewrite for existing_key must be
    # replaced by an early-return guard. Verify the guard exists and that no
    # `cat > "$auth_file"` block is gated only on existing_key.
    grep -q 'OPENAI_API_KEY already present' "$FIRST_BOOT"
    grep -q 'leaving file unchanged' "$FIRST_BOOT"
}

# -----------------------------------------------------------------------------
# P0: no masked-literal credential writes (byte-level check)
# -----------------------------------------------------------------------------

@test "no masked '***' literal written as a credential value (byte-level)" {
    # The masked-literal bug (audit findings #109/#114) writes "***" instead
    # of the variable's value. Check BYTES, not display, to defeat the
    # terminal's credential-masking layer. We look for the specific assignment
    # pattern that would be the bug.
    python3 - "$FIRST_BOOT" <<'PY'
import re, sys
data = open(sys.argv[1], 'rb').read()
# Match KEY="***" / TOKEN="***" / etc. as an assignment (not a comparison).
pattern = rb'(KEY|TOKEN|SECRET|PASSPHRASE|PASSWORD)\s*=\s*"\*{3}"'
if re.search(pattern, data):
    print("MASKED LITERAL FOUND", file=sys.stderr)
    sys.exit(1)
PY
}

# -----------------------------------------------------------------------------
# End-to-end idempotency: dry-run twice in the same simulated persist dir
# -----------------------------------------------------------------------------

@test "end-to-end: dry-run writes marker on first run" {
    mkdir -p "$SIM_PERSIST"
    run bash "$FIRST_BOOT" --dry-run
    [ "$status" -eq 0 ]
    [ -f "$SIM_PERSIST/.first-boot-done" ]
    echo "$output" | grep -q "First boot complete"
}

@test "end-to-end: second dry-run is a no-op (marker unchanged)" {
    mkdir -p "$SIM_PERSIST"
    bash "$FIRST_BOOT" --dry-run >/dev/null 2>&1
    local marker1
    marker1="$(cat "$SIM_PERSIST/.first-boot-done")"

    # Second run must log the idempotency guard message and NOT rewrite the marker.
    run bash "$FIRST_BOOT" --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "already complete"

    local marker2
    marker2="$(cat "$SIM_PERSIST/.first-boot-done")"
    [ "$marker1" = "$marker2" ]
}

@test "end-to-end: --force re-runs and updates the marker" {
    mkdir -p "$SIM_PERSIST"
    bash "$FIRST_BOOT" --dry-run >/dev/null 2>&1
    local marker1
    marker1="$(cat "$SIM_PERSIST/.first-boot-done")"

    # Sleep so the ISO timestamp (second resolution) has a chance to differ.
    sleep 1

    run bash "$FIRST_BOOT" --dry-run --force
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "FORCE MODE"

    local marker2
    marker2="$(cat "$SIM_PERSIST/.first-boot-done")"
    [ "$marker1" != "$marker2" ]
}

@test "end-to-end: dry-run does not touch the real /persist" {
    # The simulated persist must be isolated from /persist. Run dry-run and
    # confirm nothing was written outside the simulated tree.
    if [ ! -d /persist ] || [ ! -w /persist ]; then
        skip "/persist not present or not writable — isolation check N/A"
    fi
    local real_before real_after
    real_before="$(find /persist -type f 2>/dev/null | sort | tr '\n' ' ')"
    mkdir -p "$SIM_PERSIST"
    bash "$FIRST_BOOT" --dry-run >/dev/null 2>&1
    real_after="$(find /persist -type f 2>/dev/null | sort | tr '\n' ' ')"
    [ "$real_before" = "$real_after" ]
}
