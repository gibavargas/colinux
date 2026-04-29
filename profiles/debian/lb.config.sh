#!/usr/bin/env bash
# =============================================================================
# CodexOS Desktop — Debian Live Build Configuration
# =============================================================================
# Configures and runs debian-live (live-build) to create a bootable
# codexos-desktop ISO with XFCE4, encrypted persistence, and Electron Codex.
#
# This is the primary build entry point for the Debian desktop edition.
# It replaces the Alpine mkimage approach with live-build.
#
# Usage:
#   sudo ./lb.config.sh [--clean] [--debug] [--codex-version latest]
#
# Environment:
#   CODEX_DESKTOP_VERSION  — Codex Desktop version to bundle (default: latest)
#   CODEX_DESKTOP_CHANNEL  — stable|preview (default: stable)
#   LB_OUTPUT_DIR          — Output directory (default: ./work)
# =============================================================================
set -euo pipefail

# ── Cleanup ──────────────────────────────────────────────────────────────────
_CLEANUP_RANDIR=""
_cleanup() {
    [ -n "${_CLEANUP_RANDIR:-}" ] && rm -rf "$_CLEANUP_RANDIR" 2>/dev/null || true
}
trap _cleanup EXIT

# ── Defaults ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$PROFILE_DIR/.." && pwd)"

LB_DIR="$PROFILE_DIR/work"
LB_CACHE="$PROFILE_DIR/cache"
OUTPUT_DIR="${LB_OUTPUT_DIR:-$PROJECT_ROOT/dist}"

DISTRIBUTION="bookworm"       # Debian 12
ARCHITECTURE="amd64"
IMAGE_TYPE="iso-hybrid"       # ISO + hybrid MBR for USB boot
MIRROR="http://deb.debian.org/debian"
SECURITY_MIRROR="http://security.debian.org/debian-security"

CODEX_VERSION="${CODEX_DESKTOP_VERSION:-latest}"
CODEX_CHANNEL="${CODEX_DESKTOP_CHANNEL:-stable}"

CLEAN=false
DEBUG=false

# ── Colors ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "\n${BLUE}━━━ $* ━━━${NC}\n"; }

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean)    CLEAN=true; shift ;;
        --debug)    DEBUG=true; shift ;;
        --arch)     ARCHITECTURE="$2"; shift 2 ;;
        --codex-version) CODEX_VERSION="$2"; shift 2 ;;
        --codex-channel) CODEX_CHANNEL="$2"; shift 2 ;;
        --outdir)   OUTPUT_DIR="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--clean] [--debug] [--arch amd64] [--codex-version VER]"
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Preflight checks ─────────────────────────────────────────────────────────
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)."
        exit 1
    fi
}

check_lb() {
    if ! command -v lb >/dev/null 2>&1; then
        log_error "live-build (lb) not found."
        log_info "Install with: apt install live-build"
        exit 1
    fi
}

# ── Step 1: Install live-build dependencies ──────────────────────────────────
install_lb_deps() {
    log_step "Installing live-build dependencies"

    apt-get update -qq
    apt-get install -y --no-install-recommends \
        live-build \
        debootstrap \
        dosfstools \
        mtools \
        xorriso \
        grub-efi-amd64-bin \
        grub-pc-bin \
        squashfs-tools \
        fakeroot \
        fakechroot \
        isolinux \
        syslinux-common \
        > /dev/null 2>&1

    log_info "live-build dependencies installed"
}

# ── Step 2: Configure live-build ─────────────────────────────────────────────
configure_lb() {
    log_step "Configuring live-build"

    # Clean previous build if requested
    if $CLEAN && [ -d "$LB_DIR" ]; then
        log_info "Cleaning previous build..."
        lb clean --purge --rootdir "$LB_DIR" 2>/dev/null || rm -rf "$LB_DIR"
    fi

    mkdir -p "$LB_DIR" "$LB_CACHE"
    cd "$LB_DIR"

    # ── Run lb config ────────────────────────────────────────────────────────
    # This sets up the live-build configuration tree.

    # Base configuration
    lb config \
        --distribution "$DISTRIBUTION" \
        --architecture "$ARCHITECTURE" \
        --archive-areas "main contrib non-free non-free-firmware" \
        --mirror "$MIRROR" \
        --parent-mirror "$MIRROR" \
        --security true \
        --security-mirror "$SECURITY_MIRROR" \
        --updates true \
        --source false \
        --debug $([ "$DEBUG" = true ] && echo true || echo false) \
        --verbose true \
        \
        --binary-images "iso-hybrid" \
        --memtest none \
        \
        --bootloader "syslinux,grub-efi" \
        \
        --iso-application "CodexOS Desktop" \
        --iso-publisher "CoLinux Project" \
        --iso-volume "CODEXOS-DESKTOP" \
        \
        --apt-indices false \
        --cache-packages true \
        --cache-indices true \
        --package-lists "codexos-desktop" \
        \
        --linux-flavours "amd64" \
        \
        --firmware-binary true \
        --firmware-chroot true \
        \
        --initramfs "live-boot-initramfs-tools"

    log_info "live-build configuration complete"
}

# ── Step 3: Apply package list ───────────────────────────────────────────────
apply_packages() {
    log_step "Applying package list"

    local pkg_list_dir="$LB_DIR/config/package-lists"
    mkdir -p "$pkg_list_dir"

    # Copy our package list
    cp "$PROFILE_DIR/packages.desktop" "$pkg_list_dir/codexos-desktop.list.chroot"

    log_info "Package list applied: $(wc -l < "$PROFILE_DIR/packages.desktop") packages"
}

# ── Step 4: Apply overlay files ──────────────────────────────────────────────
apply_overlays() {
    log_step "Applying overlay files"

    local overlay_src="$PROFILE_DIR/overlay"
    local chroot_overlay="$LB_DIR/config/overlays/chroot"
    local binary_overlay="$LB_DIR/config/overlays/binary"

    mkdir -p "$chroot_overlay" "$binary_overlay"

    if [ -d "$overlay_src" ]; then
        # Copy overlay into chroot overlay
        cp -a "$overlay_src"/* "$chroot_overlay"/
        log_info "Chroot overlay applied"
    fi

    # Ensure proper permissions on overlay files
    find "$chroot_overlay" -type f -name "*.sh" -exec chmod 755 {} \;
    find "$chroot_overlay" -type f -name "*.service" -exec chmod 644 {} \;
    find "$chroot_overlay" -type f -name "*.timer" -exec chmod 644 {} \;
    find "$chroot_overlay" -type f -name "*.conf" -exec chmod 644 {} \;

    # Set overlay mode in lb config
    echo "live-build-overlay" >> "$LB_DIR/config/includes.chroot/.version" 2>/dev/null || true
}

# ── Step 5: Apply hooks ──────────────────────────────────────────────────────
apply_hooks() {
    log_step "Setting up live-build hooks"

    local hooks_dir="$LB_DIR/config/hooks"
    mkdir -p "$hooks_dir"/{normal,chroot,binary}

    # Hook: Install Node.js after chroot is set up
    cat > "$hooks_dir/normal/0200-install-nodejs.hook.chroot" <<'HOOK_EOF'
#!/bin/bash
# Install Node.js 22 LTS from NodeSource
set -euo pipefail

echo "I: Installing Node.js 22 LTS from NodeSource..."

# Install prerequisites
apt-get update -qq
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg

# Add NodeSource repository
mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg 2>/dev/null

echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list

apt-get update -qq
apt-get install -y --no-install-recommends nodejs

echo "I: Node.js $(node --version) installed"
echo "I: npm $(npm --version) installed"
HOOK_EOF
    chmod 755 "$hooks_dir/normal/0200-install-nodejs.hook.chroot"

    # Hook: Install Codex Desktop after Node.js
    cat > "$hooks_dir/normal/0300-install-codex-desktop.hook.chroot" <<HOOK_EOF
#!/bin/bash
# Build and install Codex Desktop (Electron) wrapper
set -euo pipefail

echo "I: Installing Codex Desktop..."

if [ -x /opt/codexos-setup/setup-codex-desktop.sh ]; then
    CODEX_DESKTOP_FORCE=true \
    CODEX_DESKTOP_VERSION="${CODEX_DESKTOP_VERSION:-latest}" \
    /opt/codexos-setup/setup-codex-desktop.sh
    echo "I: Codex Desktop installed"
elif command -v npm >/dev/null 2>&1; then
    # Fallback: Install codex CLI via npm for now
    echo "I: Setting up Codex CLI via npm..."
    npm install -g @anthropic-ai/codex 2>/dev/null || \
    npm install -g codex 2>/dev/null || \
    echo "W: Could not install Codex CLI via npm"
else
    echo "W: Node.js not available, Codex Desktop setup deferred to first boot"
fi
HOOK_EOF
    chmod 755 "$hooks_dir/normal/0300-install-codex-desktop.hook.chroot"

    # Hook: Clean up for smaller image
    cat > "$hooks_dir/normal/9990-cleanup.hook.chroot" <<'HOOK_EOF'
#!/bin/bash
# Clean up unnecessary files to reduce image size
set -euo pipefail

echo "I: Cleaning up for smaller image..."

# Remove apt cache
apt-get clean
rm -rf /var/lib/apt/lists/*

# Remove temporary files
rm -rf /tmp/* /var/tmp/*

# Remove docs and man pages (save ~50MB)
rm -rf /usr/share/doc/* 2>/dev/null || true
rm -rf /usr/share/man/* 2>/dev/null || true
rm -rf /usr/share/info/* 2>/dev/null || true

# Remove locale data (keep en)
rm -rf /usr/share/locale/[a-df-z]* 2>/dev/null || true
rm -rf /usr/share/locale/en_[A-Z]* 2>/dev/null || true

# Remove systemd journal
rm -rf /var/log/journal/* 2>/dev/null || true

echo "I: Cleanup complete"
HOOK_EOF
    chmod 755 "$hooks_dir/normal/9990-cleanup.hook.chroot"

    log_info "Build hooks configured"
}

# ── Step 6: Build ────────────────────────────────────────────────────────────
run_build() {
    log_step "Building ISO image"

    cd "$LB_DIR"

    export CODEX_DESKTOP_VERSION="$CODEX_VERSION"
    export CODEX_DESKTOP_CHANNEL="$CODEX_CHANNEL"

    lb build 2>&1 | tee "$LB_DIR/build.log" || {
        log_error "live-build failed! Check $LB_DIR/build.log"
        exit 1
    }

    log_info "ISO build complete"
}

# ── Step 7: Post-build ───────────────────────────────────────────────────────
post_build() {
    log_step "Post-processing"

    # Find the output ISO
    local iso_file
    iso_file="$(find "$LB_DIR" -maxdepth 1 -name '*.iso' | head -1)"

    if [ -z "$iso_file" ]; then
        log_error "No ISO file found in $LB_DIR"
        exit 1
    fi

    # Create output directory
    mkdir -p "$OUTPUT_DIR"

    # Copy and rename
    local output_file="$OUTPUT_DIR/codexos-desktop-${ARCHITECTURE}-$(date +%Y%m%d).iso"
    cp "$iso_file" "$output_file"

    # Generate checksum
    (cd "$OUTPUT_DIR" && sha256sum "$(basename "$output_file")" \
        > "$(basename "$output_file").sha256")

    log_info "Output: $output_file"
    log_info "SHA256: $(cat "${output_file}.sha256")"
    log_info "Size: $(du -h "$output_file" | cut -f1)"
}

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
    log_step "Build Complete"

    echo ""
    echo "  Edition:      codexos-desktop"
    echo "  Distribution: Debian $DISTRIBUTION"
    echo "  Architecture: $ARCHITECTURE"
    echo "  Desktop:      XFCE4"
    echo "  Codex:        v$CODEX_VERSION ($CODEX_CHANNEL channel)"
    echo ""
    echo "  Output directory: $OUTPUT_DIR"
    echo ""

    find "$OUTPUT_DIR" -maxdepth 1 -type f \( -name '*.iso' -o -name '*.sha256' \) \
        -exec ls -lh {} \; 2>/dev/null || true
    echo ""
    log_info "To test: sudo scripts/build-debian.sh --test"
    log_info "To flash: sudo dd if=<iso> of=/dev/sdX bs=4M status=progress && sync"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    log_step "CodexOS Desktop Build — Debian $DISTRIBUTION / $ARCHITECTURE"

    check_root
    check_lb
    install_lb_deps
    configure_lb
    apply_packages
    apply_overlays
    apply_hooks
    run_build
    post_build
    print_summary
}

main "$@"
