#!/usr/bin/env bash
# =============================================================================
# CoLinux — ShellCheck lint runner
# =============================================================================
# Enforces the project's shellcheck contract:
#
#   * GATING  (exit 1 on any warning):  scripts/*.sh
#   * REPORTING (informational, non-gating): all codex-* wrappers across editions
#
# The scripts/*.sh gate satisfies the v0.3 exit criterion "shellcheck
# scripts/*.sh passes with zero warnings". Wrapper warnings are surfaced for
# visibility but do not fail the gate — wrapper lint cleanup is tracked as
# follow-up hardening so operational scripts are not destabilized in bulk.
#
# Usage:
#   tests/lint/shellcheck.sh            # gate + report
#   tests/lint/shellcheck.sh --strict   # gate on wrappers too (CI hardening)
#   tests/lint/shellcheck.sh --help
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHELLCHECKRC_SOURCE="$PROJECT_ROOT/.shellcheckrc"

STRICT=false
for arg in "$@"; do
    case "$arg" in
        --strict) STRICT=true ;;
        --help|-h)
            sed -n '3,18p' "${BASH_SOURCE[0]}"
            exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "ERROR: shellcheck is not installed." >&2
    echo "  Debian/Ubuntu: sudo apt-get install shellcheck" >&2
    echo "  Alpine:        apk add shellcheck" >&2
    echo "  macOS:         brew install shellcheck" >&2
    exit 2
fi

SC_VERSION="$(shellcheck --version | awk '/^version:/ {print $2; exit}')"
echo "ShellCheck ${SC_VERSION}"
echo ""

# (shellcheck auto-discovers the .shellcheckrc from the target file's dir.)
# To guarantee the project config applies, run from the project root.
cd "$PROJECT_ROOT"

# -----------------------------------------------------------------------------
# GATE: scripts/*.sh must be warning-free.
# -----------------------------------------------------------------------------
SCRIPTS=(scripts/*.sh)
echo "━━━ GATING: scripts/*.sh (zero warnings required) ━━━"
gate_failed=0
for f in "${SCRIPTS[@]}"; do
    [ -f "$f" ] || continue
    if ! shellcheck "$f" >/dev/null 2>&1; then
        echo "  FAIL: $f"
        shellcheck "$f" || true
        gate_failed=1
    fi
done
if [ "$gate_failed" -eq 0 ]; then
    echo "  OK: all ${#SCRIPTS[@]} scripts/*.sh pass shellcheck cleanly"
else
    echo ""
    echo "❌ scripts/*.sh gate FAILED — fix the warnings above." >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# REPORT: codex-* wrappers across all editions (informational).
# -----------------------------------------------------------------------------
echo ""
echo "━━━ REPORT: codex-* wrappers across editions ━━━"
wrapper_total=0
wrapper_clean=0
wrapper_warned=0
wrapper_warnings=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    wrapper_total=$((wrapper_total + 1))
    out="$(shellcheck "$f" 2>&1 || true)"
    if [ -z "$out" ]; then
        wrapper_clean=$((wrapper_clean + 1))
    else
        wrapper_warned=$((wrapper_warned + 1))
        n="$(printf '%s\n' "$out" | grep -c '^In .*line' || true)"
        wrapper_warnings=$((wrapper_warnings + n))
    fi
done < <(python3 - "$PROJECT_ROOT" <<'PY'
import os, sys
root = sys.argv[1]
out = []
for dirpath, _dirs, files in os.walk(root):
    if os.sep + '.git' + os.sep in dirpath + os.sep or dirpath.startswith(os.path.join(root, 'tests')):
        continue
    for fn in files:
        if not fn.startswith('codex-'):
            continue
        path = os.path.join(dirpath, fn)
        try:
            with open(path, 'rb') as fh:
                first = fh.readline().decode('utf-8', 'ignore').strip()
        except OSError:
            continue
        if first.startswith('#!') and ('bin/bash' in first or 'bin/sh' in first or 'bin/ash' in first):
            out.append(path)
for p in sorted(out):
    print(p)
PY
)

echo "  wrappers scanned : $wrapper_total"
echo "  clean            : $wrapper_clean"
echo "  with warnings    : $wrapper_warned ($wrapper_warnings individual findings)"

if [ "$STRICT" = true ] && [ "$wrapper_warnings" -gt 0 ]; then
    echo ""
    echo "❌ --strict: wrapper warnings are failing the gate." >&2
    echo "   Run each: shellcheck <file>" >&2
    exit 1
fi

if [ "$wrapper_warnings" -gt 0 ]; then
    echo "  (wrapper warnings are informational; pass --strict to gate on them)"
fi

echo ""
echo "✅ shellcheck gate passed (scripts/*.sh clean)"
