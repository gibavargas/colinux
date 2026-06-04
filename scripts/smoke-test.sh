#!/usr/bin/env bash
# =============================================================================
# CoLinux Lite — Unified Smoke Test
# =============================================================================
# Provides a documented, repeatable developer validation path:
#   --docker   Build colinux-lite Docker image and validate codexctl
#   --iso      Boot built ISO in QEMU and run automated boot checks
#   --all      Run both stages (requires a built ISO for --iso stage)
#
# Usage:
#   ./scripts/smoke-test.sh --docker                    # Quick Docker validate
#   ./scripts/smoke-test.sh --iso                       # QEMU boot test (auto-finds ISO)
#   ./scripts/smoke-test.sh --iso --iso path/to.iso     # QEMU boot test (explicit ISO)
#   ./scripts/smoke-test.sh --all                       # Full pipeline
#
# Exit codes:
#   0  All requested stages passed
#   1  One or more stages failed
#   2  Missing prerequisites
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_ROOT/dist"

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

STAGE_DOCKER=false
STAGE_ISO=false
STAGE_FIRST_BOOT=false
ISO_PATH=""
DOCKER_TAG="${DOCKER_TAG:-colinux-lite:smoke-test}"
ARCH="${ARCH:-x86_64}"

# ── Logging ──────────────────────────────────────────────────────────────────
log_stage() { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${NC}\n"; }
log_pass()  { echo -e "  ${GREEN}[PASS]${NC}  $*"; }
log_fail()  { echo -e "  ${RED}[FAIL]${NC}  $*"; }
log_info()  { echo -e "  ${BLUE}[INFO]${NC}  $*"; }
log_skip()  { echo -e "  ${YELLOW}[SKIP]${NC}  $*"; }

PASS=0
FAIL=0

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --docker)      STAGE_DOCKER=true; shift ;;
        --iso)         STAGE_ISO=true; shift ;;
        --first-boot)  STAGE_FIRST_BOOT=true; shift ;;
        --all)         STAGE_DOCKER=true; STAGE_ISO=true; STAGE_FIRST_BOOT=true; shift ;;
        --iso-path)
            ISO_PATH="$2"; shift 2 ;;
        --tag)     DOCKER_TAG="$2"; shift 2 ;;
        --arch)    ARCH="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 {--docker|--iso|--first-boot|--all} [--iso-path PATH] [--tag TAG] [--arch ARCH]"
            echo ""
            echo "Stages:"
            echo "  --docker      Build Docker image and validate codexctl status"
            echo "  --iso         QEMU boot test using scripts/test-iso.sh"
            echo "  --first-boot  Run scripts/first-boot.sh --dry-run inside the Docker image"
            echo "                (validates postinstall hook execution without real boot/disk)"
            echo "  --all         Run all stages"
            echo ""
            echo "Options:"
            echo "  --iso-path PATH   Explicit ISO path (default: auto-find in dist/)"
            echo "  --tag TAG         Docker image tag (default: colinux-lite:smoke-test)"
            echo "  --arch ARCH       Target architecture (default: x86_64)"
            exit 0
            ;;
        *) echo "Unknown option: $1 (use --help)"; exit 1 ;;
    esac
done

# Default: run docker stage only if no stage specified
if ! $STAGE_DOCKER && ! $STAGE_ISO && ! $STAGE_FIRST_BOOT; then
    STAGE_DOCKER=true
fi

# ── Stage 1: Docker validation ───────────────────────────────────────────────
run_docker_stage() {
    log_stage "Stage 1: Docker Build + Validate"

    if ! command -v docker >/dev/null 2>&1; then
        log_fail "docker not found — install Docker or skip with --iso"
        FAIL=$((FAIL+1))
        return 1
    fi

    # Build
    log_info "Building Docker image: $DOCKER_TAG"
    if docker build -t "$DOCKER_TAG" "$PROJECT_ROOT" 2>&1 | tail -5; then
        log_pass "Docker build succeeded"
        PASS=$((PASS+1))
    else
        log_fail "Docker build failed"
        FAIL=$((FAIL+1))
        return 1
    fi

    # Validate: codexctl status
    log_info "Running codexctl status in container..."
    if docker run --rm --entrypoint bash "$DOCKER_TAG" -c "codexctl status" 2>&1; then
        log_pass "codexctl status succeeded"
        PASS=$((PASS+1))
    else
        log_fail "codexctl status failed"
        FAIL=$((FAIL+1))
    fi

    # Validate: syntax check all shell scripts
    log_info "Checking shell script syntax in container..."
    local syntax_errors
    syntax_errors=$(docker run --rm --entrypoint bash "$DOCKER_TAG" -c \
        'find /usr/local/bin -name "*.sh" -o -name "codex-*" -o -name "codexctl" 2>/dev/null | while read -r f; do bash -n "$f" 2>&1; done' 2>&1)
    if [ -z "$syntax_errors" ]; then
        log_pass "All container scripts pass bash -n"
        PASS=$((PASS+1))
    else
        log_fail "Syntax errors in container scripts:"
        echo "$syntax_errors" | sed 's/^/    /'
        FAIL=$((FAIL+1))
    fi

    # Validate: doas.conf references exist
    log_info "Validating doas.conf command references..."
    local doas_check
    doas_check=$(docker run --rm --entrypoint bash "$DOCKER_TAG" -c '
        missing=0
        while IFS= read -r cmd; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                echo "MISSING: $cmd"
                missing=$((missing+1))
            fi
        done < <(grep "permit nopass" /etc/doas.conf 2>/dev/null | awk "{print \$NF}")
        exit $missing
    ' 2>&1) || true
    if [ -z "$doas_check" ]; then
        log_pass "All doas.conf commands exist in container"
        PASS=$((PASS+1))
    else
        log_fail "Missing doas.conf commands:"
        echo "$doas_check" | sed 's/^/    /'
        FAIL=$((FAIL+1))
    fi
}

# ── Stage 2: ISO QEMU boot test ──────────────────────────────────────────────
run_iso_stage() {
    log_stage "Stage 2: QEMU Boot Test"

    # Find ISO
    if [ -z "$ISO_PATH" ]; then
        ISO_PATH="$(find "$DIST_DIR" -name "colinux-lite-${ARCH}-*.iso" 2>/dev/null | sort -V | tail -1)"
    fi

    if [ -z "$ISO_PATH" ] || [ ! -f "$ISO_PATH" ]; then
        log_fail "No ISO found. Build one first:"
        echo "    docker run --rm -v \"\$(pwd):/src\" -e ARCH=$ARCH -e OUTDIR=/src/dist \\"
        echo "      alpine:3.21 sh -c 'apk add --no-cache alpine-sdk apk-tools alpine-conf bash curl \\"
        echo "      ca-certificates git xorriso squashfs-tools mtools dosfstools grub grub-efi \\"
        echo "      efibootmgr e2fsprogs qemu-img openssl && cd /src && bash scripts/build-alpine.sh'"
        FAIL=$((FAIL+1))
        return 1
    fi

    log_info "ISO: $ISO_PATH"

    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        log_skip "QEMU not installed — skipping ISO boot test"
        return 0
    fi

    # Delegate to existing test-iso.sh
    log_info "Running test-iso.sh..."
    if "$SCRIPT_DIR/test-iso.sh" --iso "$ISO_PATH" --arch "$ARCH"; then
        log_pass "ISO boot test passed"
        PASS=$((PASS+1))
    else
        log_fail "ISO boot test failed — check dist/test-results.log"
        FAIL=$((FAIL+1))
    fi
}

# ── Stage 3: First-boot dry-run simulation ───────────────────────────────────
# Runs scripts/first-boot.sh --dry-run inside the Docker image with a test
# postinstall hook pre-staged. Validates:
#   - first-boot.sh runs without error in --dry-run mode
#   - the test postinstall hook executes
#   - successful hooks are removed by first-boot.sh
#   - the .first-boot-done marker is created
#   - the real /persist is NOT touched
run_first_boot_stage() {
    log_stage "Stage 3: First-Boot Dry-Run Simulation"

    if ! command -v docker >/dev/null 2>&1; then
        log_fail "docker not found — install Docker or run --first-boot on a Docker host"
        FAIL=$((FAIL+1))
        return 1
    fi

    # Ensure image exists. Build if missing; reuse if already built.
    if ! docker image inspect "$DOCKER_TAG" >/dev/null 2>&1; then
        log_info "Docker image $DOCKER_TAG not found; building..."
        if docker build -t "$DOCKER_TAG" "$PROJECT_ROOT" 2>&1 | tail -5; then
            log_pass "Docker image built for first-boot simulation"
        else
            log_fail "Docker build failed — cannot run first-boot simulation"
            FAIL=$((FAIL+1))
            return 1
        fi
    else
        log_info "Reusing existing Docker image: $DOCKER_TAG"
    fi

    # Run first-boot.sh --dry-run inside the container with a test hook staged.
    # The hook writes a marker file; first-boot.sh should then delete the hook
    # (the script removes successful hooks). We assert both behaviors.
    local fb_output
    fb_output="$(docker run --rm --entrypoint /bin/sh "$DOCKER_TAG" -c '
set -e

SIM_PERSIST=/tmp/colinux-firstboot-sim
export CODEX_PERSIST_SIM="$SIM_PERSIST"

# Pre-stage a postinstall test hook
mkdir -p "$SIM_PERSIST/config/postinstall"
cat > "$SIM_PERSIST/config/postinstall/00-smoke-test-hook.sh" <<HOOK
#!/bin/sh
echo "smoke-test-hook ran at \$(date -Iseconds)" > "$SIM_PERSIST/config/postinstall/.smoke-marker"
HOOK
chmod 755 "$SIM_PERSIST/config/postinstall/00-smoke-test-hook.sh"

# Snapshot real /persist state (file list + content hash) BEFORE dry-run.
# /persist is expected to exist in the Docker image, so we compare content
# rather than presence to detect any writes from the dry-run path.
PERSIST_BEFORE_LIST=$(find /persist -type f 2>/dev/null | sort | tr "\n" " ")
PERSIST_BEFORE_HASH=$(find /persist -type f -exec md5sum {} + 2>/dev/null | sort | md5sum | cut -d" " -f1)
echo "PERSIST_BEFORE_LIST=$PERSIST_BEFORE_LIST"
echo "PERSIST_BEFORE_HASH=$PERSIST_BEFORE_HASH"

# Run first-boot.sh in dry-run mode
/usr/local/bin/first-boot --dry-run >/tmp/fb-stdout.log 2>&1 || {
    echo "FIRST_BOOT_FAILED"
    cat /tmp/fb-stdout.log
    exit 1
}

# Verify marker written by hook
if [ -f "$SIM_PERSIST/config/postinstall/.smoke-marker" ]; then
    echo "HOOK_MARKER_OK"
else
    echo "HOOK_MARKER_MISSING"
fi

# Verify hook was deleted by first-boot.sh (successful hooks are removed)
if [ ! -f "$SIM_PERSIST/config/postinstall/00-smoke-test-hook.sh" ]; then
    echo "HOOK_REMOVED_OK"
else
    echo "HOOK_STILL_PRESENT"
fi

# Verify first-boot marker exists
if [ -f "$SIM_PERSIST/.first-boot-done" ]; then
    echo "FIRST_BOOT_FLAG_OK"
else
    echo "FIRST_BOOT_FLAG_MISSING"
fi

# Snapshot real /persist state AFTER dry-run
PERSIST_AFTER_LIST=$(find /persist -type f 2>/dev/null | sort | tr "\n" " ")
PERSIST_AFTER_HASH=$(find /persist -type f -exec md5sum {} + 2>/dev/null | sort | md5sum | cut -d" " -f1)
echo "PERSIST_AFTER_LIST=$PERSIST_AFTER_LIST"
echo "PERSIST_AFTER_HASH=$PERSIST_AFTER_HASH"

# Show dry-run banner confirmation from the log
grep -q "DRY-RUN MODE" "$SIM_PERSIST/logs/first-boot.log" && echo "DRY_RUN_LOG_OK" || echo "DRY_RUN_LOG_MISSING"
' 2>&1)"

    # Evaluate results
    if echo "$fb_output" | grep -q '^FIRST_BOOT_FAILED$'; then
        log_fail "first-boot.sh --dry-run exited non-zero"
        echo "$fb_output" | sed 's/^/    /'
        FAIL=$((FAIL+1))
        return 1
    fi
    log_pass "first-boot.sh --dry-run completed"
    PASS=$((PASS+1))

    if echo "$fb_output" | grep -q '^HOOK_MARKER_OK$'; then
        log_pass "Postinstall hook executed"
        PASS=$((PASS+1))
    else
        log_fail "Postinstall hook did not write marker"
        echo "$fb_output" | sed 's/^/    /'
        FAIL=$((FAIL+1))
    fi

    if echo "$fb_output" | grep -q '^HOOK_REMOVED_OK$'; then
        log_pass "Successful hook removed by first-boot.sh"
        PASS=$((PASS+1))
    else
        log_fail "Hook was not removed after successful execution"
        echo "$fb_output" | sed 's/^/    /'
        FAIL=$((FAIL+1))
    fi

    if echo "$fb_output" | grep -q '^FIRST_BOOT_FLAG_OK$'; then
        log_pass "First-boot marker written"
        PASS=$((PASS+1))
    else
        log_fail "First-boot marker missing"
        echo "$fb_output" | sed 's/^/    /'
        FAIL=$((FAIL+1))
    fi

    if echo "$fb_output" | grep -q '^DRY_RUN_LOG_OK$'; then
        log_pass "Dry-run banner present in first-boot log"
        PASS=$((PASS+1))
    else
        log_fail "Dry-run banner missing from first-boot log"
        FAIL=$((FAIL+1))
    fi

    # Critical safety: real /persist must not have been touched. We compare a
    # content hash rather than presence because the Docker image ships a
    # /persist/config/auto-update.conf for boot-time paths.
    local persist_hash_before persist_hash_after persist_list_before persist_list_after
    persist_hash_before="$(echo "$fb_output" | sed -n 's/^PERSIST_BEFORE_HASH=//p')"
    persist_hash_after="$(echo "$fb_output" | sed -n 's/^PERSIST_AFTER_HASH=//p')"
    persist_list_before="$(echo "$fb_output" | sed -n 's/^PERSIST_BEFORE_LIST=//p')"
    persist_list_after="$(echo "$fb_output" | sed -n 's/^PERSIST_AFTER_LIST=//p')"
    if [ -n "$persist_hash_before" ] && [ "$persist_hash_before" = "$persist_hash_after" ]; then
        log_pass "Real /persist not modified by dry-run (content hash unchanged)"
        PASS=$((PASS+1))
    else
        log_fail "Real /persist content changed during dry-run"
        echo "    before: $persist_list_before"
        echo "    after:  $persist_list_after"
        FAIL=$((FAIL+1))
    fi
}

# ── Main ─────────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}CoLinux Lite — Smoke Test${NC}"
    echo "  Architecture: $ARCH"
    echo "  Stages:$( $STAGE_DOCKER && echo ' docker')$( $STAGE_ISO && echo ' iso')$( $STAGE_FIRST_BOOT && echo ' first-boot')"
    echo ""

    if $STAGE_DOCKER; then
        run_docker_stage || true
    fi

    if $STAGE_ISO; then
        run_iso_stage || true
    fi

    if $STAGE_FIRST_BOOT; then
        run_first_boot_stage || true
    fi

    log_stage "Results"
    echo "  Passed: $PASS"
    echo "  Failed: $FAIL"
    echo ""

    if [ "$FAIL" -gt 0 ]; then
        echo -e "${RED}❌ $FAIL test(s) failed${NC}"
        return 1
    else
        echo -e "${GREEN}✅ All tests passed${NC}"
        return 0
    fi
}

main
