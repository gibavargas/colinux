#!/usr/bin/env bash
# =============================================================================
# CoLinux — install bats-core locally (no sudo / system install required)
# =============================================================================
# Clones bats-core and the standard helper libraries into tests/.bats/ so the
# unit test suite runs on any developer machine and CI runner without touching
# the system. The vendored copy is gitignored.
#
# Usage:
#   tests/install-bats.sh             # install if missing
#   tests/install-bats.sh --force     # reinstall
#   tests/install-bats.sh --help
#
# Environment:
#   BATS_VERSION     pin a specific bats-core release tag (default: v1.11.x HEAD)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BATS_DIR="$SCRIPT_DIR/.bats"
FORCE=false

for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=true ;;
        --help|-h)
            sed -n '3,20p' "${BASH_SOURCE[0]}"
            exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

# Already on PATH? Prefer a system bats if present.
if command -v bats >/dev/null 2>&1 && [ "$FORCE" != true ]; then
    echo "Using system bats: $(command -v bats)"
    bats --version
    exit 0
fi

if [ -x "$BATS_DIR/bin/bats" ] && [ "$FORCE" != true ]; then
    echo "Using vendored bats: $BATS_DIR/bin/bats"
    "$BATS_DIR/bin/bats" --version
    exit 0
fi

echo "Installing bats-core into $BATS_DIR ..."

if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git is required to install bats-core." >&2
    exit 2
fi

rm -rf "$BATS_DIR"
mkdir -p "$BATS_DIR"

clone() {
    local repo="$1" dest="$2"
    if git clone --depth 1 "$repo" "$dest" 2>&1; then
        return 0
    fi
    echo "ERROR: failed to clone $repo" >&2
    return 1
}

clone https://github.com/bats-core/bats-core.git "$BATS_DIR/core"
clone https://github.com/bats-core/bats-support.git "$BATS_DIR/test_helper/bats-support"
clone https://github.com/bats-core/bats-assert.git  "$BATS_DIR/test_helper/bats-assert"

# Expose bats at $BATS_DIR/bin/bats so callers can prepend it to PATH.
ln -sf "$BATS_DIR/core/bin/bats" "$BATS_DIR/bin/bats" 2>/dev/null || true
mkdir -p "$BATS_DIR/bin"
ln -sf "$BATS_DIR/core/bin/bats" "$BATS_DIR/bin/bats"

echo ""
echo "✅ bats installed at $BATS_DIR/bin/bats"
"$BATS_DIR/bin/bats" --version
echo ""
echo "Add to PATH for this session:"
echo "  export PATH=\"$BATS_DIR/bin:\$PATH\""
