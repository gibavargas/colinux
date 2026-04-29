#!/usr/bin/env bash
# =============================================================================
# CodexOS Lite — Release Script
# =============================================================================
# Creates release artifacts from the dist/ directory:
#   • ISO image
#   • Raw disk image
#   • QCOW2 image (if QEMU tools available)
#   • SHA256 checksums
#   • GPG signature (if GPG key available)
#   • Release manifest JSON
#
# Usage:
#   ./release.sh [--outdir ./dist] [--version 0.1.0] [--gpg-key KEY_ID]
#   GPG_KEY=ABCDEF01 ./release.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Defaults ─────────────────────────────────────────────────────────────────
OUTDIR="${OUTDIR:-$PROJECT_ROOT/dist}"
VERSION="${VERSION:-}"
GPG_KEY="${GPG_KEY:-}"
RELEASE_DIR="$OUTDIR/release"
ARCH="${ARCH:-x86_64}"

# ── Colors ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' NC=''
fi
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --outdir)  OUTDIR="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --gpg-key) GPG_KEY="$2"; shift 2 ;;
        --arch)    ARCH="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--outdir DIR] [--version VER] [--gpg-key ID] [--arch ARCH]"
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Auto-detect version from ISO filename ────────────────────────────────────
if [ -z "$VERSION" ]; then
    local_iso="$(find "$OUTDIR" -maxdepth 1 -name 'codexos-lite-*.iso' 2>/dev/null | head -1)"
    if [ -n "$local_iso" ]; then
        # Extract version-like string from filename: codexos-lite-x86_64-3.21.0.iso
        VERSION="$(basename "$local_iso" | grep -oP '[\d]+\.[\d]+(\.[\d]+)?' | head -1)"
    fi
fi
VERSION="${VERSION:-0.0.0}"

# ── Setup release directory ─────────────────────────────────────────────────
mkdir -p "$RELEASE_DIR"

# ── Collect artifacts ────────────────────────────────────────────────────────
log_info "Collecting release artifacts..."

ARTIFACTS=()

# ISO
for f in "$OUTDIR"/codexos-lite-*.iso; do
    [ -f "$f" ] && ARTIFACTS+=("$f")
done

# Raw images
for f in "$OUTDIR"/codexos-lite-*.raw.img; do
    [ -f "$f" ] && ARTIFACTS+=("$f")
done

# QCOW2 images
for f in "$OUTDIR"/codexos-lite-*.qcow2; do
    [ -f "$f" ] && ARTIFACTS+=("$f")
done

if [ ${#ARTIFACTS[@]} -eq 0 ]; then
    log_error "No artifacts found in $OUTDIR"
    exit 1
fi

log_info "Found ${#ARTIFACTS[@]} artifact(s):"
for a in "${ARTIFACTS[@]}"; do
    echo "  • $(basename "$a") ($(du -h "$a" | cut -f1))"
done

# ── Copy artifacts to release dir ────────────────────────────────────────────
for a in "${ARTIFACTS[@]}"; do
    cp "$a" "$RELEASE_DIR/"
done

# ── Generate SHA256 checksums ───────────────────────────────────────────────
log_info "Generating SHA256 checksums..."
CHECKSUM_FILE="$RELEASE_DIR/SHA256SUMS"
(
    cd "$RELEASE_DIR"
    sha256sum codexos-lite-* > "$CHECKSUM_FILE"
)
log_info "Checksums: $CHECKSUM_FILE"
cat "$CHECKSUM_FILE"

# ── GPG sign (if key available) ──────────────────────────────────────────────
if [ -n "$GPG_KEY" ] && command -v gpg >/dev/null 2>&1; then
    log_info "Signing checksums with GPG key: $GPG_KEY"

    # Sign the checksums file
    gpg --batch --yes --local-user "$GPG_KEY" --armor --detach-sign "$CHECKSUM_FILE"

    # Sign each artifact individually
    for a in "$RELEASE_DIR"/codexos-lite-*; do
        [ -f "$a" ] || continue
        case "$(basename "$a")" in
            *.asc|*.sig|SHA256SUMS*) continue ;;
        esac
        gpg --batch --yes --local-user "$GPG_KEY" --armor --detach-sign "$a"
        log_info "Signed: $(basename "$a")"
    done
elif [ -n "$GPG_KEY" ]; then
    log_warn "GPG key specified but gpg not found. Skipping signing."
else
    log_info "No GPG key specified. Skipping signing."
    log_info "To sign: GPG_KEY=<key-id> $0"
fi

# ── Generate release manifest ────────────────────────────────────────────────
log_info "Generating release manifest..."
MANIFEST_FILE="$RELEASE_DIR/release.json"

# Get current Codex version if available
CODEX_VER="unknown"
if command -v codex >/dev/null 2>&1; then
    CODEX_VER="$(codex --version 2>/dev/null | head -1 || echo unknown)"
fi

# Build manifest
cat > "$MANIFEST_FILE" <<MANIFEST
{
  "name": "codexos-lite",
  "version": "$VERSION",
  "arch": "$ARCH",
  "codex_version": "$CODEX_VER",
  "build_date": "$(date -Iseconds)",
  "build_host": "$(hostname -s 2>/dev/null || echo unknown)",
  "artifacts": [
$(for a in "${ARTIFACTS[@]}"; do
    bn="$(basename "$a")"
    sz="$(stat -c%s "$a" 2>/dev/null || echo 0)"
    sha="$(sha256sum "$a" | cut -d' ' -f1)"
    echo "    {\"name\": \"$bn\", \"size\": $sz, \"sha256\": \"$sha\"},"
done | sed '$ s/,$//')
  ]
}
MANIFEST

log_info "Manifest: $MANIFEST_FILE"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║           CodexOS Lite $VERSION — Release             ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  Release directory: $RELEASE_DIR"
echo "║  Checksums:          SHA256SUMS"
echo "║  Manifest:           release.json"
echo "║  Signed:             $([ -n "$GPG_KEY" ] && echo "yes ($GPG_KEY)" || echo "no")"
echo "║                                                          ║"

for f in "$RELEASE_DIR"/codexos-lite-*; do
    [ -f "$f" ] || continue
    echo "║  $(printf "%-18s %s" "$(basename "$f"):" "$(du -h "$f" | cut -f1)")"
done

echo "║                                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
log_info "Release artifacts ready in $RELEASE_DIR"
