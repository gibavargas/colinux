#!/usr/bin/env bats
# =============================================================================
# CoLinux — codex-update-os unit suite (v0.5 deliverable: OS-level updates)
# =============================================================================
# Exercises the A/B OS image updater WITHOUT real block devices:
#   - argument parsing & usage
#   - tar archive member validation (path traversal, symlinks, hardlinks)
#   - SHA256SUMS verification + signature-gate policy (fail-closed by default)
#   - A/B layout discovery (dual-slot vs single-slot fallback)
#   - inactive slot selection + slot_dev resolution
#   - trial state (ab-pending.json) writing/clearing
#   - bootcheck confirm path (health ok → pending cleared, slot confirmed)
#   - bootcheck revert path (health fail + max attempts → rollback)
#   - manual rollback from a pending trial
#
# Block-device operations (mount/umount/write_slot/update_boot_config) are
# exercised via dry-run where possible, and the pure helpers are unit-tested
# directly by sourcing the script with `bash -c` subshells so the script's
# top-level dispatch never runs.
# =============================================================================

load "../lib/helpers"

_UPDATE_OS="$COLINUX_ROOT/profiles/alpine/overlay/usr/local/bin/codex-update-os"
_HEALTH="$COLINUX_ROOT/profiles/alpine/overlay/usr/local/lib/colinux/health-check.sh"

# Source the script's functions into a subshell without running main dispatch.
# Usage: _sourced_body <extra_exports> <<'BODY'
# The BODY is bash that calls the sourced functions and echoes results.
_run_sourced() {
    local extra="$1"; shift
    local body
    body="$(cat)"
    bash -c "
        set -euo pipefail
        $extra
        # Stub functions that touch disks/network so sourcing is side-effect-free.
        colinux_init_output() { :; }
        colinux_result() { :; }
        colinux_die() { echo \"ERROR: \$*\" >&2; exit 1; }
        colinux_confirm() { return 0; }
        # shellcheck source=/dev/null
        source '$_UPDATE_OS' || exit 99
        $body
    "
}

# ─── Setup/teardown ───────────────────────────────────────────────────────
setup() {
    export COLINUX_TEST_TMP="$(mktemp -d)"
    export COLINUX_PERSIST_DIR="$COLINUX_TEST_TMP/persist"
    export COLINUX_ESP_MNT="$COLINUX_TEST_TMP/esp"
    mkdir -p "$COLINUX_PERSIST_DIR/state" "$COLINUX_PERSIST_DIR/logs" "$COLINUX_ESP_MNT"
    # No release key by default → fail-closed unless --insecure-no-sig
    export COLINUX_AB_MAX_BOOT_ATTEMPTS=3
}

teardown() {
    [[ -n "${COLINUX_TEST_TMP:-}" ]] && rm -rf "$COLINUX_TEST_TMP"
}

# ─── Argument parsing ────────────────────────────────────────────────────
@test "codex-update-os --help exits 0 and documents key options" {
    run "$_UPDATE_OS" --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"--check"* ]]
    [[ "$output" == *"--rollback"* ]]
    [[ "$output" == *"--bootcheck"* ]]
    [[ "$output" == *"--from"* ]]
    [[ "$output" == *"--insecure-no-sig"* ]]
    [[ "$output" == *"A/B"* ]]
}

@test "codex-update-os rejects unknown options" {
    run "$_UPDATE_OS" --bogus
    [[ "$status" -ne 0 ]]
}

@test "codex-update-os is syntactically valid (bash -n)" {
    bash -n "$_UPDATE_OS"
}

@test "codex-update-os declares a bash shebang on line 1" {
    [[ "$(head -1 "$_UPDATE_OS")" == "#!/bin/bash" ]]
}

@test "codex-update-os enables strict error mode" {
    grep -q 'set -euo pipefail' "$_UPDATE_OS"
}

@test "codex-update-os references a logs path" {
    grep -q 'logs' "$_UPDATE_OS"
}

@test "codex-update-os honors the --json structured-output contract" {
    grep -q -- '--json' "$_UPDATE_OS"
    grep -q 'COLINUX_JSON' "$_UPDATE_OS"
    grep -q 'colinux_die' "$_UPDATE_OS"
}

# ─── Archive member validation ───────────────────────────────────────────
@test "validate_tar_archive rejects absolute paths" {
    local arc="$COLINUX_TEST_TMP/bad.tar.gz"
    mkdir -p "$COLINUX_TEST_TMP/src"
    echo data > "$COLINUX_TEST_TMP/src/etc-passwd"
    tar czf "$arc" -C "$COLINUX_TEST_TMP/src" etc-passwd >/dev/null
    # Rewrite the member name to an absolute path using a known-bad prefix.
    # Simpler: build a tar with an absolute member via GNU tar --transform is
    # awkward; instead craft a tar whose single member is "/evil".
    mkdir -p "$COLINUX_TEST_TMP/absroot"
    echo x > "$COLINUX_TEST_TMP/absroot/evil"
    ( cd "$COLINUX_TEST_TMP/absroot" && tar czf "$arc" --transform='s,^,/,/' evil ) >/dev/null 2>&1 \
        || tar czf "$arc" -P -C "$COLINUX_TEST_TMP/absroot" /evil >/dev/null 2>&1 || true
    # If we couldn't craft an absolute-member tar on this platform, skip gracefully.
    if ! tar tzf "$arc" 2>/dev/null | grep -q '^/'; then
        skip "could not synthesize absolute-member tar on this host"
    fi
    run _run_sourced "" <<'BODY'
validate_tar_archive "$COLINUX_TEST_TMP/bad.tar.gz"
BODY
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"Unsafe archive member path"* ]]
}

@test "validate_tar_archive rejects symlink entries" {
    local arc="$COLINUX_TEST_TMP/link.tar.gz"
    mkdir -p "$COLINUX_TEST_TMP/links"
    ln -sf /etc/passwd "$COLINUX_TEST_TMP/links/escape"
    tar czf "$arc" -C "$COLINUX_TEST_TMP/links" escape >/dev/null 2>&1 || true
    # Confirm the archive actually contains a symlink entry before asserting.
    if ! tar tvzf "$arc" 2>/dev/null | grep -q 'escape'; then
        skip "could not synthesize symlink tar on this host"
    fi
    run _run_sourced "" <<'BODY'
validate_tar_archive "$COLINUX_TEST_TMP/link.tar.gz"
BODY
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"symlink or hardlink"* ]]
}

@test "validate_tar_archive accepts a clean payload-shaped archive" {
    local arc="$COLINUX_TEST_TMP/good.tar.gz"
    mkdir -p "$COLINUX_TEST_TMP/payload"
    echo squash > "$COLINUX_TEST_TMP/payload/system.squashfs"
    echo kernel > "$COLINUX_TEST_TMP/payload/vmlinuz-lts"
    echo initrd > "$COLINUX_TEST_TMP/payload/initramfs-lts"
    printf '{"version":"1.0"}\n' > "$COLINUX_TEST_TMP/payload/manifest.json"
    ( cd "$COLINUX_TEST_TMP" && tar czf "$arc" payload ) >/dev/null
    run _run_sourced "" <<'BODY'
validate_tar_archive "$COLINUX_TEST_TMP/good.tar.gz"
echo "OK"
BODY
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"OK"* ]]
}

# ─── SHA256SUMS verification + signature policy ─────────────────────────
@test "verify_payload fails closed when SHA256SUMS is missing" {
    mkdir -p "$COLINUX_TEST_TMP/pl"
    echo x > "$COLINUX_TEST_TMP/pl/system.squashfs"
    run _run_sourced "" <<'BODY'
verify_payload "$COLINUX_TEST_TMP/pl" >/dev/null 2>&1 && echo PASS || echo FAIL
BODY
    [[ "$output" == *"FAIL"* ]]
}

@test "verify_payload rejects a checksum mismatch" {
    mkdir -p "$COLINUX_TEST_TMP/pl"
    echo good > "$COLINUX_TEST_TMP/pl/system.squashfs"
    printf '0000000000000000000000000000000000000000000000000000000000000000  system.squashfs\n' \
        > "$COLINUX_TEST_TMP/pl/SHA256SUMS"
    run _run_sourced "" <<'BODY'
verify_payload "$COLINUX_TEST_TMP/pl" >/dev/null 2>&1 && echo PASS || echo FAIL
BODY
    [[ "$output" == *"FAIL"* ]]
}

@test "verify_payload accepts matching SHA256SUMS with --insecure-no-sig" {
    mkdir -p "$COLINUX_TEST_TMP/pl"
    echo good > "$COLINUX_TEST_TMP/pl/system.squashfs"
    local sum
    sum="$(sha256sum "$COLINUX_TEST_TMP/pl/system.squashfs" | awk '{print $1}')"
    printf '%s  system.squashfs\n' "$sum" > "$COLINUX_TEST_TMP/pl/SHA256SUMS"
    run _run_sourced "" <<'BODY'
ALLOW_NO_SIG=true
verify_payload "$COLINUX_TEST_TMP/pl" >/dev/null 2>&1 && echo PASS || echo FAIL
BODY
    [[ "$output" == *"PASS"* ]]
}

@test "verify_payload REFUSES without key when not --insecure-no-sig" {
    mkdir -p "$COLINUX_TEST_TMP/pl"
    echo good > "$COLINUX_TEST_TMP/pl/system.squashfs"
    local sum
    sum="$(sha256sum "$COLINUX_TEST_TMP/pl/system.squashfs" | awk '{print $1}')"
    printf '%s  system.squashfs\n' "$sum" > "$COLINUX_TEST_TMP/pl/SHA256SUMS"
    run _run_sourced "" <<'BODY'
ALLOW_NO_SIG=false
# Force find_release_key to find nothing by pointing the paths at missing files.
RELEASE_KEY_PERSIST="$COLINUX_TEST_TMP/nope.gpg"
RELEASE_KEY_BAKED="$COLINUX_TEST_TMP/nope2.gpg"
verify_payload "$COLINUX_TEST_TMP/pl" >/dev/null 2>&1 && echo PASS || echo FAIL
BODY
    [[ "$output" == *"FAIL"* ]]
}

# ─── A/B layout discovery ───────────────────────────────────────────────
@test "discover_layout enters single-slot mode when only one system dev is given" {
    mkdir -p "$COLINUX_TEST_TMP/single"
    run _run_sourced "" <<'BODY'
COLINUX_SLOT_A_DEV=""
COLINUX_SLOT_B_DEV=""
COLINUX_SLOT_SINGLE_DEV="$COLINUX_TEST_TMP/single/dev-sda"
COLINUX_ESP_DEV=""
# blkid/lsblk will find nothing → falls back to single via COLINUX_SLOT_SINGLE_DEV
discover_layout
echo "SINGLE=$SINGLE_MODE SLOT_A=$SLOT_A_DEV ACTIVE=$ACTIVE_SLOT"
BODY
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"SINGLE=true"* ]]
    [[ "$output" == *"ACTIVE=A"* ]]
}

@test "discover_layout selects inactive slot B when A is active (A/B mode)" {
    run _run_sourced "" <<'BODY'
COLINUX_SLOT_A_DEV="/dev/fakeA"
COLINUX_SLOT_B_DEV="/dev/fakeB"
COLINUX_ESP_DEV="/dev/fakeESP"
COLINUX_ACTIVE_SLOT="A"
discover_layout
echo "INACTIVE=$(inactive_slot) DEVB=$(slot_dev B) SINGLE=$SINGLE_MODE"
BODY
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"INACTIVE=B"* ]]
    [[ "$output" == *"DEVB=/dev/fakeB"* ]]
    [[ "$output" == *"SINGLE=false"* ]]
}

@test "discover_layout rejects an invalid active slot state" {
    run _run_sourced "" <<'BODY'
COLINUX_SLOT_A_DEV="/dev/fakeA"
COLINUX_SLOT_B_DEV="/dev/fakeB"
COLINUX_ACTIVE_SLOT="Z"
discover_layout
BODY
    [[ "$status" -ne 0 ]]
}

# ─── Trial state ─────────────────────────────────────────────────────────
@test "set_trial writes ab-pending.json with the expected fields" {
    run _run_sourced "" <<'BODY'
PENDING_STATE="$COLINUX_TEST_TMP/persist/state/ab-pending.json"
set_trial "B" "A" "9.9.9"
cat "$PENDING_STATE"
BODY
    [[ "$status" -eq 0 ]]
    [[ "$output" == *'"new_slot":"B"'* ]]
    [[ "$output" == *'"prev_slot":"A"'* ]]
    [[ "$output" == *'"version":"9.9.9"'* ]]
    [[ "$output" == *'"status":"trial"'* ]]
}

@test "clear_pending removes the trial record" {
    echo '{"status":"trial"}' > "$COLINUX_PERSIST_DIR/state/ab-pending.json"
    run _run_sourced "" <<'BODY'
PENDING_STATE="$COLINUX_TEST_TMP/persist/state/ab-pending.json"
clear_pending
[[ -f "$PENDING_STATE" ]] && echo STILL || echo GONE
BODY
    [[ "$output" == *"GONE"* ]]
}

# ─── Bootcheck: confirm & revert ─────────────────────────────────────────
@test "bootcheck confirms a trial when health checks pass" {
    # Build a pending record pointing at slot B (prev A).
    cat > "$COLINUX_PERSIST_DIR/state/ab-pending.json" <<EOF
{"new_slot":"B","prev_slot":"A","version":"9.9.9","status":"trial","boot_attempts":0,"max_boot_attempts":3}
EOF
    echo "A" > "$COLINUX_PERSIST_DIR/state/ab-slot"
    # Override the active layout + health script (passing) + skip real ESP/disk.
    local ok_health="$COLINUX_TEST_TMP/health-ok.sh"
    printf '#!/bin/bash\nexit 0\n' > "$ok_health"
    chmod +x "$ok_health"
    run _run_sourced "" <<BODY
SLOT_STATE="$COLINUX_TEST_TMP/persist/state/ab-slot"
PENDING_STATE="$COLINUX_TEST_TMP/persist/state/ab-pending.json"
HEALTH_SCRIPT="$ok_health"
DRY_RUN=true
# update_boot_config is a dry-run no-op here.
COLINUX_SLOT_A_DEV="/dev/fakeA"
COLINUX_SLOT_B_DEV="/dev/fakeB"
COLINUX_ACTIVE_SLOT="B"
discover_layout
do_bootcheck
echo "SLOT=\$(cat "$COLINUX_TEST_TMP/persist/state/ab-slot") PENDING=\$([[ -f "$COLINUX_TEST_TMP/persist/state/ab-pending.json" ]] && echo YES || echo NO)"
BODY
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Health checks passed"* ]]
    # Pending cleared and slot confirmed as B.
    [[ "$output" == *"PENDING=NO"* ]]
}

@test "bootcheck reverts after max_boot_attempts when health keeps failing" {
    cat > "$COLINUX_PERSIST_DIR/state/ab-pending.json" <<EOF
{"new_slot":"B","prev_slot":"A","version":"9.9.9","status":"trial","boot_attempts":2,"max_boot_attempts":3}
EOF
    echo "B" > "$COLINUX_PERSIST_DIR/state/ab-slot"
    local fail_health="$COLINUX_TEST_TMP/health-fail.sh"
    printf '#!/bin/bash\nexit 1\n' > "$fail_health"
    chmod +x "$fail_health"
    run _run_sourced "" <<BODY
SLOT_STATE="$COLINUX_TEST_TMP/persist/state/ab-slot"
PENDING_STATE="$COLINUX_TEST_TMP/persist/state/ab-pending.json"
HEALTH_SCRIPT="$fail_health"
DRY_RUN=true
COLINUX_SLOT_A_DEV="/dev/fakeA"
COLINUX_SLOT_B_DEV="/dev/fakeB"
COLINUX_ACTIVE_SLOT="B"
discover_layout
do_bootcheck
echo "SLOT=\$(cat "$COLINUX_TEST_TMP/persist/state/ab-slot") PENDING=\$([[ -f "$COLINUX_TEST_TMP/persist/state/ab-pending.json" ]] && echo YES || echo NO)"
BODY
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"Max boot attempts reached"* ]]
    [[ "$output" == *"SLOT=A"* ]]
    [[ "$output" == *"PENDING=NO"* ]]
}

# ─── Rollback ────────────────────────────────────────────────────────────
@test "manual rollback from a pending trial restores the previous slot" {
    cat > "$COLINUX_PERSIST_DIR/state/ab-pending.json" <<EOF
{"new_slot":"B","prev_slot":"A","version":"9.9.9","status":"trial","boot_attempts":1,"max_boot_attempts":3}
EOF
    echo "B" > "$COLINUX_PERSIST_DIR/state/ab-slot"
    run _run_sourced "" <<BODY
SLOT_STATE="$COLINUX_TEST_TMP/persist/state/ab-slot"
PENDING_STATE="$COLINUX_TEST_TMP/persist/state/ab-pending.json"
DRY_RUN=true
COLINUX_SLOT_A_DEV="/dev/fakeA"
COLINUX_SLOT_B_DEV="/dev/fakeB"
COLINUX_ACTIVE_SLOT="B"
discover_layout
do_rollback >/dev/null 2>&1 && echo OK || echo FAIL
echo "SLOT=\$(cat "$COLINUX_TEST_TMP/persist/state/ab-slot") PENDING=\$([[ -f "$COLINUX_TEST_TMP/persist/state/ab-pending.json" ]] && echo YES || echo NO)"
BODY
    [[ "$output" == *"OK"* ]]
    [[ "$output" == *"SLOT=A"* ]]
    [[ "$output" == *"PENDING=NO"* ]]
}

@test "rollback fails cleanly when there is nothing to roll back" {
    run _run_sourced "" <<BODY
SLOT_STATE="$COLINUX_TEST_TMP/persist/state/ab-slot"
PENDING_STATE="$COLINUX_TEST_TMP/persist/state/ab-pending.json"
COLINUX_SLOT_A_DEV="/dev/fakeA"
COLINUX_SLOT_B_DEV="/dev/fakeB"
COLINUX_ACTIVE_SLOT="A"
discover_layout
do_rollback
BODY
    [[ "$status" -ne 0 ]]
}

# ─── Dry-run update path ─────────────────────────────────────────────────
@test "do_update --dry-run validates, verifies, and stages without writing" {
    # Build a valid signed-checksum-less payload; use --insecure-no-sig.
    local bundle="$COLINUX_TEST_TMP/os.tar.gz"
    mkdir -p "$COLINUX_TEST_TMP/src"
    echo squash > "$COLINUX_TEST_TMP/src/system.squashfs"
    echo kernel > "$COLINUX_TEST_TMP/src/vmlinuz-lts"
    echo initrd > "$COLINUX_TEST_TMP/src/initramfs-lts"
    printf '{"version":"9.9.9","arch":"x86_64"}\n' > "$COLINUX_TEST_TMP/src/manifest.json"
    ( cd "$COLINUX_TEST_TMP" && tar czf "$bundle" src ) >/dev/null
    # Rewrite SHA256SUMS for the payload members under their bare names.
    mkdir -p "$COLINUX_TEST_TMP/sumsrc"
    cp "$COLINUX_TEST_TMP/src/"* "$COLINUX_TEST_TMP/sumsrc/"
    ( cd "$COLINUX_TEST_TMP/sumsrc" && sha256sum system.squashfs vmlinuz-lts initramfs-lts manifest.json > SHA256SUMS )
    ( cd "$COLINUX_TEST_TMP" && tar czf "$bundle" -C sumsrc . ) >/dev/null

    run _run_sourced "" <<BODY
ALLOW_NO_SIG=true
DRY_RUN=true
PAYLOAD_FILE="$bundle"
FORCE=true
COLINUX_SLOT_A_DEV="/dev/fakeA"
COLINUX_SLOT_B_DEV="/dev/fakeB"
COLINUX_ACTIVE_SLOT="A"
COLINUX_ESP_DEV=""
discover_layout
do_update >/dev/null 2>&1 && echo OK || echo FAIL
BODY
    [[ "$output" == *"OK"* ]]
}

# ─── Health-check helper ────────────────────────────────────────────────
@test "health-check.sh is syntactically valid" {
    bash -n "$_HEALTH"
}

@test "health-check.sh declares a bash shebang on line 1" {
    [[ "$(head -1 "$_HEALTH")" == "#!/bin/bash" ]]
}
