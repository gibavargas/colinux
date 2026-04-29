#!/usr/bin/env bash
# =============================================================================
# CodexOS Lite — Codex CLI Setup Script
# =============================================================================
# Downloads and installs the OpenAI Codex CLI musl binary.
# Supports x86_64 and aarch64 architectures.
#
# Usage:
#   ./setup-codex.sh [--version latest|X.Y.Z] [--force] [--prefix /usr/local]
#   CODEX_VERSION=0.1.0 ./setup-codex.sh
#
# The binary is installed to /usr/local/bin/codex by default.
# =============================================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
INSTALL_DIR="$INSTALL_PREFIX/bin"
INSTALL_PATH="$INSTALL_DIR/codex"
GITHUB_REPO="openai/codex"
FORCE="${FORCE:-false}"
CODEX_VERSION="${CODEX_VERSION:-latest}"
CHANNEL="${CHANNEL:-stable}"   # stable or preview

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
        --version) CODEX_VERSION="$2"; shift 2 ;;
        --force)   FORCE=true; shift ;;
        --prefix)  INSTALL_PREFIX="$2"; INSTALL_DIR="$INSTALL_PREFIX/bin"; INSTALL_PATH="$INSTALL_DIR/codex"; shift 2 ;;
        --channel) CHANNEL="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--version VER] [--force] [--prefix DIR] [--channel stable|preview]"
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Detect architecture ──────────────────────────────────────────────────────
detect_arch() {
    local arch
    arch="$(uname -m)"

    case "$arch" in
        x86_64|amd64)
            echo "x86_64-unknown-linux-musl"
            ;;
        aarch64|arm64)
            echo "aarch64-unknown-linux-musl"
            ;;
        *)
            log_error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
}

# ── Check if already installed and current ───────────────────────────────────
check_existing() {
    if [ "$FORCE" = "true" ]; then
        return 1  # Force reinstall
    fi

    if [ ! -x "$INSTALL_PATH" ]; then
        return 1  # Not installed
    fi

    # Check if current version matches desired
    local current_ver
    current_ver="$("$INSTALL_PATH" --version 2>/dev/null | head -1 | grep -oP '[\d.]+' | head -1 || echo "")"

    if [ "$CODEX_VERSION" = "latest" ]; then
        # Always update if version is "latest"
        log_info "Currently installed: $current_ver (checking for update)"
        return 1
    fi

    if [ "$current_ver" = "$CODEX_VERSION" ]; then
        log_info "Codex CLI $current_ver is already installed. Use --force to reinstall."
        return 0
    fi

    return 1
}

# ── Get latest release version from GitHub ───────────────────────────────────
get_latest_version() {
    local url="https://api.github.com/repos/${GITHUB_REPO}/releases/${CHANNEL}"

    # If channel is "preview", use "latest" endpoint but filter
    if [ "$CHANNEL" = "preview" ]; then
        url="https://api.github.com/repos/${GITHUB_REPO}/releases"
    fi

    local version
    version="$(curl -fsSL "$url" 2>/dev/null | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -1)"

    if [ -z "$version" ]; then
        log_error "Could not determine latest version from GitHub API."
        exit 1
    fi

    echo "$version"
}

# ── Download Codex CLI ──────────────────────────────────────────────────────
download_codex() {
    local arch_triple
    arch_triple="$(detect_arch)"

    local version="$CODEX_VERSION"
    if [ "$version" = "latest" ]; then
        version="$(get_latest_version)"
        log_info "Latest version: $version"
    fi

    local filename="codex-${arch_triple}.tar.gz"
    local download_url

    if [ "$CHANNEL" = "preview" ]; then
        download_url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${filename}"
    else
        download_url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${filename}"
    fi

    log_info "Downloading Codex CLI $version for $arch_triple..."
    log_info "URL: $download_url"

    local tmpdir
    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" EXIT

    # Download with retry
    local attempts=0
    local max_attempts=3

    while [ $attempts -lt $max_attempts ]; do
        attempts=$((attempts + 1))
        if curl -fsSL --retry-connrefused --retry-delay 3 \
            --connect-timeout 30 \
            -o "$tmpdir/$filename" "$download_url"; then
            break
        fi
        log_warn "Download attempt $attempts failed."
        if [ $attempts -ge $max_attempts ]; then
            log_error "Failed to download after $max_attempts attempts."
            exit 1
        fi
        sleep 5
    done

    # Verify download size (should be at least 1MB for a real binary)
    local dl_size
    dl_size="$(stat -c%s "$tmpdir/$filename" 2>/dev/null || echo 0)"
    if [ "$dl_size" -lt 1048576 ]; then
        log_error "Downloaded file is suspiciously small (${dl_size} bytes)."
        log_error "The file may be an error page. Check the URL manually."
        exit 1
    fi

    # Extract
    log_info "Extracting archive..."
    tar xzf "$tmpdir/$filename" -C "$tmpdir" 2>/dev/null || {
        log_error "Failed to extract archive."
        exit 1
    }

    # Find the binary
    local binary
    binary="$(find "$tmpdir" -name 'codex' -type f ! -name '*.tar.gz' | head -1)"
    if [ -z "$binary" ]; then
        log_error "Could not find codex binary in extracted archive."
        log_error "Archive contents:"
        find "$tmpdir" -type f 2>/dev/null
        exit 1
    fi

    # Verify the binary is valid (ELF or similar)
    if file "$binary" | grep -qi "ELF\|executable"; then
        log_info "Binary validated: $(file "$binary" | cut -d: -f2-)"
    else
        log_warn "Binary type unexpected: $(file "$binary")"
        log_warn "Proceeding anyway..."
    fi

    # Install
    mkdir -p "$INSTALL_DIR"
    cp "$binary" "$INSTALL_PATH"
    chmod 755 "$INSTALL_PATH"

    log_info "Codex CLI $version installed to $INSTALL_PATH"
    echo "$version"
}

# ── Verify installation ──────────────────────────────────────────────────────
verify_install() {
    if [ ! -x "$INSTALL_PATH" ]; then
        log_error "Installation verification failed: $INSTALL_PATH not executable"
        return 1
    fi

    local ver
    ver="$("$INSTALL_PATH" --version 2>/dev/null || echo "unknown")"
    log_info "Installed version: $ver"

    # Test basic help output
    if "$INSTALL_PATH" --help >/dev/null 2>&1; then
        log_info "Binary smoke test: PASS"
    else
        log_warn "Binary smoke test: help command returned error (may be normal)"
    fi

    return 0
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    log_info "=== CodexOS — Codex CLI Setup ==="
    log_info "Architecture: $(uname -m)"
    log_info "Install path: $INSTALL_PATH"
    log_info "Channel:      $CHANNEL"
    log_info "Version:      $CODEX_VERSION"

    # Check prerequisites
    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl is required but not found."
        exit 1
    fi

    if ! command -v tar >/dev/null 2>&1; then
        log_error "tar is required but not found."
        exit 1
    fi

    # Check if update needed
    if check_existing; then
        exit 0
    fi

    # Download and install
    local installed_version
    installed_version="$(download_codex)"

    # Verify
    verify_install

    log_info "=== Setup complete ==="
    echo ""
    echo "  Codex CLI $installed_version installed successfully."
    echo "  Binary: $INSTALL_PATH"
    echo "  Run 'codex' to start."
}

main "$@"
