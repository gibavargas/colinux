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
        --docker)  STAGE_DOCKER=true; shift ;;
        --iso)     STAGE_ISO=true; shift ;;
        --all)     STAGE_DOCKER=true; STAGE_ISO=true; shift ;;
        --iso-path)
            ISO_PATH="$2"; shift 2 ;;
        --tag)     DOCKER_TAG="$2"; shift 2 ;;
        --arch)    ARCH="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 {--docker|--iso|--all} [--iso-path PATH] [--tag TAG] [--arch ARCH]"
            echo ""
            echo "Stages:"
            echo "  --docker   Build Docker image and validate codexctl status"
            echo "  --iso      QEMU boot test using scripts/test-iso.sh"
            echo "  --all      Run both stages"
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
if ! $STAGE_DOCKER && ! $STAGE_ISO; then
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

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo -e "${BOLD}CoLinux Lite — Smoke Test${NC}"
    echo "  Architecture: $ARCH"
    echo "  Stages:$( $STAGE_DOCKER && echo ' docker')$( $STAGE_ISO && echo ' iso')"
    echo ""

    if $STAGE_DOCKER; then
        run_docker_stage || true
    fi

    if $STAGE_ISO; then
        run_iso_stage || true
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
