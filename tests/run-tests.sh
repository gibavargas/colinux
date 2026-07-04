#!/usr/bin/env bash
# =============================================================================
# CoLinux — master test runner
# =============================================================================
# Single entry point for the CoLinux test harness:
#
#   tests/run-tests.sh           # lint + unit (default)
#   tests/run-tests.sh lint      # shellcheck gate on scripts/*.sh (+ report)
#   tests/run-tests.sh unit      # bats unit + contract suite
#   tests/run-tests.sh iso       # ISO boot regression (delegates to test-iso.sh)
#   tests/run-tests.sh all       # lint + unit + iso (iso needs a built ISO)
#
# Exit codes:
#   0  all requested suites passed
#   1  one or more suites failed
#   2  missing prerequisites
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
if [ ! -t 1 ]; then RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''; fi

PASS=0; FAIL=0
stage() { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${NC}\n"; }
ok()    { echo -e "  ${GREEN}[PASS]${NC}  $*"; PASS=$((PASS+1)); }
bad()   { echo -e "  ${RED}[FAIL]${NC}  $*"; FAIL=$((FAIL+1)); }
info()  { echo -e "  ${BLUE}[INFO]${NC}  $*"; }

run_lint() {
    stage "Suite: shellcheck lint"
    if "$SCRIPT_DIR/lint/shellcheck.sh"; then
        ok "shellcheck gate passed"
    else
        bad "shellcheck gate failed"
        return 1
    fi
}

resolve_bats() {
    # Prefer system bats, then vendored copy.
    if command -v bats >/dev/null 2>&1; then
        command -v bats
        return 0
    fi
    if [ -x "$SCRIPT_DIR/.bats/bin/bats" ]; then
        echo "$SCRIPT_DIR/.bats/bin/bats"
        return 0
    fi
    info "bats not found — installing locally (no sudo)..." >&2
    if "$SCRIPT_DIR/install-bats.sh" >&2; then
        echo "$SCRIPT_DIR/.bats/bin/bats"
        return 0
    fi
    return 1
}

run_unit() {
    stage "Suite: bats unit tests"
    local bats_bin
    if ! bats_bin="$(resolve_bats)"; then
        bad "could not obtain bats"
        return 1
    fi
    info "Using: $bats_bin"
    if "$bats_bin" "$SCRIPT_DIR/unit"; then
        ok "bats unit suite passed"
    else
        bad "bats unit suite failed"
        return 1
    fi
}

run_iso() {
    stage "Suite: ISO boot regression"
    local runner="$PROJECT_ROOT/scripts/test-iso.sh"
    if [ ! -x "$runner" ]; then
        echo -e "  ${YELLOW}[SKIP]${NC}  test-iso.sh not executable"
        return 0
    fi
    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        echo -e "  ${YELLOW}[SKIP]${NC}  QEMU not installed (install: apt install qemu-system-x86)"
        return 0
    fi
    if "$runner" --help >/dev/null 2>&1; then
        if "$runner"; then
            ok "ISO boot regression passed"
        else
            bad "ISO boot regression failed (needs a built ISO in dist/)"
            return 1
        fi
    else
        echo -e "  ${YELLOW}[SKIP]${NC}  test-iso.sh could not run"
    fi
}

usage() {
    sed -n '3,21p' "${BASH_SOURCE[0]}"
}

# Argument parsing
SUITES=()
if [ $# -eq 0 ]; then
    SUITES=(lint unit)
fi
while [ $# -gt 0 ]; do
    case "$1" in
        lint)  SUITES+=(lint) ;;
        unit)  SUITES+=(unit) ;;
        iso)   SUITES+=(iso) ;;
        all)   SUITES+=(lint unit iso) ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown suite: $1 (use --help)" >&2; exit 2 ;;
    esac
    shift
done

# Deduplicate suites while preserving order.
seen=""
ORDERED=()
for s in "${SUITES[@]}"; do
    case " $seen " in *" $s "*) continue ;; esac
    seen="$seen $s"; ORDERED+=("$s")
done

rc=0
for s in "${ORDERED[@]}"; do
    case "$s" in
        lint) run_lint  || rc=1 ;;
        unit) run_unit  || rc=1 ;;
        iso)  run_iso   || rc=1 ;;
    esac
done

stage "Summary"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""
if [ "$rc" -ne 0 ]; then
    echo -e "${RED}❌ test run failed${NC}"
else
    echo -e "${GREEN}✅ test run passed${NC}"
fi
exit "$rc"
