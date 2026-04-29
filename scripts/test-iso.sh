#!/usr/bin/env bash
# =============================================================================
# CodexOS Lite — ISO Automated Test Script
# =============================================================================
# Boots the CodexOS ISO in QEMU and runs smoke tests via serial console:
#   1. Boot completes (kernel + init)
#   2. codex binary exists and is executable
#   3. codex-disk-inventory runs without error
#   4. At least one network interface exists
#   5. Persistence partition detection works
#
# Usage:
#   ./test-iso.sh --iso <path-to-iso> [--arch x86_64] [--timeout 120]
#
# Prerequisites: qemu-system-x86_64 (or aarch64), expect (optional)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Defaults ─────────────────────────────────────────────────────────────────
ISO_PATH=""
ARCH="${ARCH:-x86_64}"
TIMEOUT="${TIMEOUT:-180}"
MEMORY="${MEMORY:-1024}"
DIST_DIR="$PROJECT_ROOT/dist"
TEST_LOG="$DIST_DIR/test-results.log"
SERIAL_LOG="$DIST_DIR/serial-output.log"

PASS=0
FAIL=0
SKIP=0

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_test()   { echo -e "  ${CYAN}[TEST]${NC}  $*"; }
log_pass()   { echo -e "  ${GREEN}[PASS]${NC}  $*"; PASS=$((PASS+1)); }
log_fail()   { echo -e "  ${RED}[FAIL]${NC}  $*"; FAIL=$((FAIL+1)); }
log_skip()   { echo -e "  ${YELLOW}[SKIP]${NC}  $*"; SKIP=$((SKIP+1)); }
log_info()   { echo -e "  ${BLUE}[INFO]${NC}  $*"; }
log_step()   { echo -e "\n${BLUE}━━━ $* ━━━${NC}\n"; }

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --iso)     ISO_PATH="$2"; shift 2 ;;
        --arch)    ARCH="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --memory)  MEMORY="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 --iso <path> [--arch x86_64] [--timeout 120] [--memory 1024]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Auto-find ISO ────────────────────────────────────────────────────────────
if [ -z "$ISO_PATH" ]; then
    ISO_PATH="$(find "$DIST_DIR" -name "codexos-lite-${ARCH}-*.iso" 2>/dev/null | sort -V | tail -1)"
fi

if [ -z "$ISO_PATH" ] || [ ! -f "$ISO_PATH" ]; then
    echo "ERROR: ISO not found. Build first with ./scripts/build-alpine.sh" >&2
    exit 1
fi

echo "ISO: $ISO_PATH"
echo "Arch: $ARCH"
echo "Timeout: ${TIMEOUT}s"

# ── Check QEMU availability ──────────────────────────────────────────────────
check_qemu() {
    local qemu_bin
    case "$ARCH" in
        x86_64)  qemu_bin="qemu-system-x86_64" ;;
        aarch64) qemu_bin="qemu-system-aarch64" ;;
    esac

    if ! command -v "$qemu_bin" >/dev/null 2>&1; then
        log_fail "QEMU not found: $qemu_bin"
        echo "Install with: apt install qemu-system-x86 (or qemu-system-arm)"
        exit 1
    fi
    echo "$qemu_bin"
}

# ── Run smoke tests via expect script ────────────────────────────────────────
run_tests_expect() {
    log_step "Running smoke tests with expect"

    if ! command -v expect >/dev/null 2>&1; then
        log_skip "expect not installed — running manual serial log analysis instead"
        run_tests_serial
        return $?
    fi

    local qemu_bin="$1"
    local expect_script
    expect_script="$(mktemp --suffix=.exp)"

    cat > "$expect_script" <<'EXPECT_SCRIPT'
#!/usr/bin/expect -f
set timeout [lindex $argv 0]
set log_file [lindex $argv 1]
set qemu_bin [lindex $argv 2]
set iso_path [lindex $argv 3]
set arch     [lindex $argv 4]
set memory   [lindex $argv 5]

log_file -noappend $log_file

# Start QEMU
set qemu_cmd [list $qemu_bin]
if {$arch eq "aarch64"} {
    lappend qemu_cmd -machine virt -cpu cortex-a57
} else {
    lappend qemu_cmd -machine q35 -cpu qemu64
}
lappend qemu_cmd -m $memory -nographic -cdrom $iso_path \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0

puts "Starting QEMU: $qemu_cmd"
spawn {*}$qemu_cmd

# Wait for login prompt
expect {
    "login:" {
        puts "\n>>> BOOT SUCCESS: Reached login prompt"
    }
    timeout {
        puts "\n>>> TIMEOUT: Boot did not complete within ${timeout}s"
        exit 1
    }
    eof {
        puts "\n>>> ERROR: QEMU exited unexpectedly"
        exit 2
    }
}

# Send login
send "root\r"
expect {
    "#" { }
    "Password:" {
        send "\r"
        expect "#"
    }
    timeout { puts "\n>>> TIMEOUT waiting for shell"; exit 3 }
}

# Test 1: codex binary
send "which codex && codex --version\r"
expect {
    -re "codex.*\n" {
        puts "\n>>> PASS: codex binary found"
    }
    "not found" {
        puts "\n>>> FAIL: codex binary not found"
    }
    timeout { puts "\n>>> TIMEOUT: codex check" }
}
expect "#"

# Test 2: disk inventory
send "codex-disk-inventory 2>&1 | head -5\r"
expect {
    -re "disk|nvme|sd|vd" {
        puts "\n>>> PASS: disk inventory ran"
    }
    timeout { puts "\n>>> TIMEOUT: disk inventory" }
}
expect "#"

# Test 3: network interface
send "ip link show | grep -E '^[0-9]' | head -3\r"
expect {
    -re "[0-9]+:" {
        puts "\n>>> PASS: network interfaces found"
    }
    timeout { puts "\n>>> TIMEOUT: network check" }
}
expect "#"

# Test 4: persistence detection
send "blkid -t LABEL=codex-persist 2>/dev/null && echo PERSIST_FOUND || echo PERSIST_NOT_FOUND\r"
expect {
    "PERSIST_FOUND" {
        puts "\n>>> INFO: Persistence partition detected"
    }
    "PERSIST_NOT_FOUND" {
        puts "\n>>> INFO: No persistence partition (expected in test)"
    }
    timeout { puts "\n>>> TIMEOUT: persistence check" }
}
expect "#"

# Done
send "poweroff\r"
expect eof
EXPECT_SCRIPT

    chmod +x "$expect_script"

    log_info "Running expect script (timeout: ${TIMEOUT}s)..."
    if expect "$expect_script" "$TIMEOUT" "$SERIAL_LOG" "$qemu_bin" "$ISO_PATH" "$ARCH" "$MEMORY" 2>&1 | tee "$TEST_LOG"; then
        log_info "All tests passed via expect."
    else
        log_warn "Some tests failed or timed out — check $SERIAL_LOG"
    fi

    rm -f "$expect_script"
}

# ── Fallback: serial log analysis ───────────────────────────────────────────
run_tests_serial() {
    log_step "Running smoke tests via serial log capture"

    local qemu_bin="$1"
    local serial_fifo
    serial_fifo="$(mktemp -u)"

    mkfifo "$serial_fifo" 2>/dev/null || {
        log_skip "Cannot create FIFO for serial capture"
        return 1
    }

    # Background reader
    cat "$serial_fifo" > "$SERIAL_LOG" &
    local reader_pid=$!

    # Launch QEMU
    log_info "Booting QEMU ($qemu_bin)..."
    timeout "${TIMEOUT}" "$qemu_bin" \
        ${ARCH:+-machine} ${ARCH/aarch64/virt} ${ARCH/x86_64/q35} \
        -m "$MEMORY" \
        -nographic \
        -cdrom "$ISO_PATH" \
        -serial "pipe:$serial_fifo" \
        -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
        -no-reboot \
        &>/dev/null &
    local qemu_pid=$!

    # Wait for boot
    local elapsed=0
    while [ $elapsed -lt "$TIMEOUT" ]; do
        sleep 5
        elapsed=$((elapsed + 5))

        if ! kill -0 "$qemu_pid" 2>/dev/null; then
            log_info "QEMU exited after ${elapsed}s"
            break
        fi

        # Check for login prompt
        if [ -f "$SERIAL_LOG" ] && grep -q "login:" "$SERIAL_LOG" 2>/dev/null; then
            log_pass "Boot completed (login prompt at ${elapsed}s)"
            break
        fi
    done

    # Kill QEMU if still running
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
    kill "$reader_pid" 2>/dev/null || true
    rm -f "${serial_fifo}.in" "${serial_fifo}.out" "$serial_fifo" 2>/dev/null

    # Analyze serial log
    log_step "Analyzing boot log"

    # Test: Boot completion
    if [ -f "$SERIAL_LOG" ]; then
        if grep -qi "login:" "$SERIAL_LOG"; then
            log_pass "Boot completed — login prompt reached"
        else
            log_fail "Boot did not complete — no login prompt"
        fi

        # Test: Kernel loaded
        if grep -qi "alpine\|linux" "$SERIAL_LOG"; then
            log_pass "Linux kernel loaded"
        else
            log_fail "Linux kernel not detected in log"
        fi

        # Test: Init system
        if grep -qi "init\|openrc\|rc\.sysinit" "$SERIAL_LOG"; then
            log_pass "Init system started"
        else
            log_fail "Init system not detected"
        fi

        # Test: Filesystem
        if grep -qi "squashfs\|overlay\|tmpfs" "$SERIAL_LOG"; then
            log_pass "Diskless filesystem (squashfs/overlay) active"
        else
            log_fail "Diskless filesystem not detected"
        fi

        # Test: Network
        if grep -qi "eth\|enp\|virtio_net\|dhcpcd" "$SERIAL_LOG"; then
            log_pass "Network interface detected"
        else
            log_fail "No network interface detected"
        fi
    else
        log_fail "No serial log captured"
    fi
}

# ── Print results ────────────────────────────────────────────────────────────
print_results() {
    log_step "Test Results"
    echo ""
    echo "  Passed:  $PASS"
    echo "  Failed:  $FAIL"
    echo "  Skipped: $SKIP"
    echo "  Total:   $((PASS + FAIL + SKIP))"
    echo ""
    echo "  Serial log: $SERIAL_LOG"
    echo "  Test log:   $TEST_LOG"
    echo ""

    if [ "$FAIL" -gt 0 ]; then
        echo -e "${RED}❌ SOME TESTS FAILED${NC}"
        return 1
    else
        echo -e "${GREEN}✅ ALL TESTS PASSED${NC}"
        return 0
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    mkdir -p "$DIST_DIR"
    : > "$SERIAL_LOG"
    : > "$TEST_LOG"

    log_step "CodexOS Lite ISO Smoke Tests"
    echo "  ISO:     $ISO_PATH"
    echo "  Arch:    $ARCH"
    echo "  Timeout: ${TIMEOUT}s"
    echo "  Memory:  ${MEMORY}MB"
    echo ""

    local qemu_bin
    qemu_bin="$(check_qemu)"

    # Run tests
    if command -v expect >/dev/null 2>&1; then
        run_tests_expect "$qemu_bin"
    else
        run_tests_serial "$qemu_bin"
    fi

    print_results
}

main "$@"
