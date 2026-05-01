#!/usr/bin/env bash
# =============================================================================
# CoLinux Desktop Edition — Full Build Script
# =============================================================================
# Builds the colinux-desktop Debian live ISO with XFCE4, Codex Desktop (Electron),
# and all overlay configurations.
#
# Usage:
#   ./scripts/build-debian.sh              # Full build
#   ./scripts/build-debian.sh --quick      # Skip Codex Desktop download
#   ./scripts/build-debian.sh --test       # Build + QEMU test
#   ./scripts/build-debian.sh --clean      # Clean build artifacts
#
# Requirements:
#   - Debian bookworm (build host)
#   - sudo/root access
#   - 8GB+ free disk space
#   - live-build, debootstrap
#
# Output:
#   work/debian-build/colinux-desktop-<date>.iso
#   work/debian-build/colinux-desktop-<date>.img (raw USB image)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_DIR="$PROJECT_DIR/profiles/debian"
BUILD_DIR="$PROJECT_DIR/work/debian-build"
WORK_DIR="$BUILD_DIR/work"
OUTPUT_DIR="$BUILD_DIR/output"

# Build options
QUICK=false
RUN_TEST=false
CLEAN_ONLY=false
FORCE=false
CODEX_DESKTOP_VERSION=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()    { echo -e "${BLUE}[BUILD]${NC} $*"; }
ok()     { echo -e "${GREEN}  ✓${NC} $*"; }
warn()   { echo -e "${YELLOW}  !${NC} $*"; }
err()    { echo -e "${RED}  ✗${NC} $*" >&2; }
step()   { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick)    QUICK=true; shift ;;
        --test)     RUN_TEST=true; shift ;;
        --clean)    CLEAN_ONLY=true; shift ;;
        --force)    FORCE=true; shift ;;
        --version)  CODEX_DESKTOP_VERSION="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--quick] [--test] [--clean] [--force] [--version V]"
            echo "  --quick   Skip Codex Desktop download (use cached)"
            echo "  --test    Run QEMU after build"
            echo "  --clean   Remove build artifacts"
            echo "  --force   Force rebuild from scratch"
            echo "  --version Specify Codex Desktop version"
            exit 0
            ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Prerequisites ────────────────────────────────────────────────────────────
check_prerequisites() {
    step "Checking prerequisites"

    local missing=()

    for cmd in lb debootstrap squashfs-tools xorriso mksquashfs dpkg-dev; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log "Installing missing packages: ${missing[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y live-build debootstrap squashfs-tools xorriso \
            dpkg-dev fakeroot cpio dosfstools mtools grub-efi-amd64-bin \
            grub-pc-bin syslinux isolinux 2>&1 || {
            err "Failed to install prerequisites"
            exit 1
        }
    fi

    ok "All prerequisites available"
}

# ── Clean ────────────────────────────────────────────────────────────────────
do_clean() {
    step "Cleaning build artifacts"
    if [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
        ok "Removed $BUILD_DIR"
    fi
    log "Clean complete"
}

# ── Setup build directory ────────────────────────────────────────────────────
setup_build_dir() {
    step "Setting up build directory"
    mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

    # Copy profile
    if $FORCE || [ ! -d "$BUILD_DIR/profile" ]; then
        rm -rf "${BUILD_DIR:?}/profile"
        cp -a "$PROFILE_DIR" "$BUILD_DIR/profile"
        ok "Profile copied"
    else
        ok "Using existing profile (use --force to rebuild)"
    fi
}

# ── Download Codex Desktop ───────────────────────────────────────────────────
download_codex_desktop() {
    step "Downloading Codex Desktop (Electron)"

    if $QUICK && [ -d "$BUILD_DIR/codex-desktop-cache" ]; then
        log "Using cached Codex Desktop (--quick)"
        return 0
    fi

    local cache_dir="$BUILD_DIR/codex-desktop-cache"
    mkdir -p "$cache_dir"

    log "Cloning codex-desktop-linux repository..."
    if [ ! -d "$cache_dir/codex-desktop-linux" ]; then
        git clone --depth 1 https://github.com/ilysenko/codex-desktop-linux.git \
            "$cache_dir/codex-desktop-linux" 2>&1 || {
            warn "Clone failed — will retry during build"
            return 0
        }
    else
        (cd "$cache_dir/codex-desktop-linux" && git pull 2>/dev/null) || true
    fi

    # Download latest Codex release (for the binary)
    log "Checking latest Codex release..."
    local latest_release
    latest_release="$(curl -fsSL -H "Accept: application/vnd.github+json" \
        https://api.github.com/repos/openai/codex/releases/latest 2>/dev/null \
        | jq -r '.tag_name // "latest"' 2>/dev/null)" || latest_release="latest"

    log "Latest Codex release: $latest_release"

    # Download macOS Codex app (the source for the Electron wrapper)
    local codex_url
    codex_url="https://github.com/openai/codex/releases/download/${latest_release}/codex-macos.zip"
    local codex_zip="$cache_dir/codex-macos.zip"

    if [ ! -f "$codex_zip" ]; then
        log "Downloading Codex desktop release..."
        if curl -fsSL --connect-timeout 30 -o "$codex_zip" "$codex_url" 2>/dev/null; then
            local dl_size
            dl_size="$(stat -c%s "$codex_zip" 2>/dev/null || echo 0)"
            if [ "$dl_size" -lt 1048576 ]; then
                warn "Download seems too small ($(numfmt --to=iec "$dl_size")), will retry during build"
                rm -f "$codex_zip"
            else
                ok "Downloaded Codex v$latest_release ($(numfmt --to=iec "$dl_size"))"
            fi
        else
            warn "Codex download failed — will retry during build"
        fi
    else
        ok "Using cached Codex download"
    fi

    # Record version for later use
    echo "$latest_release" > "$cache_dir/version.txt"

    ok "Codex Desktop source prepared"
}

# ── Configure live-build ─────────────────────────────────────────────────────
configure_lb() {
    step "Configuring live-build"

    cd "$BUILD_DIR"

    # Initialize live-build config
    # Explicitly set Debian mirrors to avoid inheriting Ubuntu runner defaults
    # Force Debian security mirror — live-build auto-detects from the host's
    # /etc/apt/sources.list which is Ubuntu on GitHub runners (security.ubuntu.com).
    export LB_PARENT_MIRROR_CHROOT_SECURITY="http://security.debian.org/debian-security"
    export LB_PARENT_MIRROR_BINARY_SECURITY="http://security.debian.org/debian-security"
    export LB_MIRROR_CHROOT_SECURITY="http://security.debian.org/debian-security"
    export LB_MIRROR_BINARY_SECURITY="http://security.debian.org/debian-security"

    lb config \
        --distribution bookworm \
        --debian-installer none \
        --architectures amd64 \
        --archive-areas main \
        --mirror-bootstrap http://deb.debian.org/debian \
        --mirror-chroot http://deb.debian.org/debian \
        --mirror-binary http://deb.debian.org/debian \
        --parent-mirror-bootstrap http://deb.debian.org/debian \
        --parent-mirror-chroot http://deb.debian.org/debian \
        --parent-mirror-binary http://deb.debian.org/debian \
        --bootloader syslinux,grub-efi \
        --memtest none \
        --source false \
        --binary-images iso-hybrid \
        --iso-application "CoLinux Desktop" \
        --iso-publisher "CoLinux Project" \
        --iso-volume "colinux-desktop" \
        --linux-flavours "amd64" \
        --firmware-binary true \
        --firmware-chroot true \
        --apt-indices false \
        --cache-packages true \
        --cache-indices true \
        --initramfs systemd \
        2>&1

    # Override security mirror to use Debian's (not Ubuntu's)
    # live-build inherits the runner's security mirror (security.ubuntu.com) which
    # does not serve Debian packages. Force Debian's security mirror in all stages.
    for cfg in bootstrap chroot binary; do
        cat > "$BUILD_DIR/config/archives/security.${cfg}.list" <<EOF
deb http://security.debian.org/debian-security bookworm-security main
EOF
    done

    # Also override chroot_sources if lb config generated them pointing to Ubuntu
    for cfg in chroot binary; do
        if [ -f "$BUILD_DIR/config/chroot_sources/security.${cfg}" ]; then
            sed -i 's|security.ubuntu.com/ubuntu|security.debian.org/debian-security|g' \
                "$BUILD_DIR/config/chroot_sources/security.${cfg}"
            sed -i 's|jammy|bookworm-security|g' \
                "$BUILD_DIR/config/chroot_sources/security.${cfg}"
        fi
    done

    # Hook: clean up any inherited Ubuntu apt sources inside the chroot early
    cat > "$BUILD_DIR/config/hooks/0001-fix-apt-sources.chroot" <<'HOOK'
#!/bin/bash
set -e
# Replace any leftover Ubuntu sources with pure Debian ones
cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian bookworm main
deb http://security.debian.org/debian-security bookworm-security main
deb http://deb.debian.org/debian bookworm-updates main
EOF
# Also fix any Ubuntu entries in sources.list.d
if [ -d /etc/apt/sources.list.d ]; then
    sed -i 's|security.ubuntu.com|security.debian.org/debian-security|g' \
        /etc/apt/sources.list.d/*.list 2>/dev/null || true
fi
HOOK
    chmod 755 "$BUILD_DIR/config/hooks/0001-fix-apt-sources.chroot"

    ok "live-build configured"

    # ── Install package list ─────────────────────────────────────────────
    if [ -f "$BUILD_DIR/profile/packages.desktop" ]; then
        cp "$BUILD_DIR/profile/packages.desktop" \
            "$BUILD_DIR/config/package-lists/desktop.list.chroot"
        ok "Package list installed"
    fi

    # ── Install overlay ─────────────────────────────────────────────────
    log "Installing overlay filesystem..."
    local overlay_src="$BUILD_DIR/profile/overlay"

    # Copy overlay to chroot overlay directory
    if [ -d "$overlay_src" ]; then
        mkdir -p "$BUILD_DIR/config/overlays/colinux/chroot"
        cp -a "$overlay_src"/. "$BUILD_DIR/config/overlays/colinux/chroot"/

        # Fix permissions
        find "$BUILD_DIR/config/overlays/colinux/chroot" -type d -exec chmod 755 {} \;
        find "$BUILD_DIR/config/overlays/colinux/chroot/usr/local/bin" -type f -exec chmod 755 {} \;

        ok "Overlay installed ($(find "$overlay_src" -type f | wc -l) files)"
    else
        warn "No overlay directory found at $overlay_src"
    fi

    # ── Install hooks ───────────────────────────────────────────────────
    mkdir -p "$BUILD_DIR/config/hooks"

    # Post-chroot hook: setup Codex Desktop
    cat > "$BUILD_DIR/config/hooks/9999-setup-codex-desktop.chroot" <<'HOOK'
#!/bin/bash
set -e

echo "=== CoLinux: Installing Codex Desktop ==="

# Copy setup script
if [ -f "/opt/colinux-setup/setup-codex-desktop.sh" ]; then
    chmod +x /opt/colinux-setup/setup-codex-desktop.sh
    # Don't run during build — let first-boot handle it
    # (network may not be available in chroot)
    echo "Setup script staged for first boot"
fi

# Set correct permissions
chown -R root:root /usr/local/bin/codex-* 2>/dev/null || true
chmod 755 /usr/local/bin/codex-* 2>/dev/null || true

# Set codex user home
if id codex &>/dev/null; then
    chown -R codex:codex /home/codex 2>/dev/null || true
fi

# Enable systemd services
systemctl enable codex-update.timer 2>/dev/null || true
systemctl enable codex-firstboot.service 2>/dev/null || true
systemctl enable codex-disk-inventory.service 2>/dev/null || true
systemctl enable NetworkManager 2>/dev/null || true
systemctl enable lightdm 2>/dev/null || true

echo "=== CoLinux: Desktop setup complete ==="
HOOK
    chmod 755 "$BUILD_DIR/config/hooks/9999-setup-codex-desktop.chroot"

    ok "Hooks installed"
}

# ── Build ────────────────────────────────────────────────────────────────────
do_build() {
    step "Building ISO (this may take 10-30 minutes)"

    cd "$BUILD_DIR"

    # Run live-build
    if lb build 2>&1 | tee "$BUILD_DIR/build.log"; then
        ok "Build completed successfully"
    else
        local exit_code=$?
        err "Build failed with exit code $exit_code"
        err "Check $BUILD_DIR/build.log for details"
        exit $exit_code
    fi

    # Find output ISO
    local iso
    iso="$(find "$BUILD_DIR" -maxdepth 1 -name '*.iso' -type f | head -1)"

    if [ -z "$iso" ]; then
        err "No ISO found after build"
        exit 1
    fi

    # Copy to output directory with versioned name
    local versioned_name
    versioned_name="colinux-desktop-$(date +%Y%m%d-%H%M%S).iso"

    cp "$iso" "$OUTPUT_DIR/$versioned_name"
    ok "ISO: $OUTPUT_DIR/$versioned_name ($(du -h "$OUTPUT_DIR/$versioned_name" | cut -f1))"

    # Also create raw USB image
    create_usb_image "$OUTPUT_DIR/$versioned_name" || true

    # Record build info
    {
        echo "build_date=$(date -Iseconds)"
        echo "iso_name=$versioned_name"
        echo "iso_size=$(stat -c%s "$OUTPUT_DIR/$versioned_name")"
        echo "codex_version=$(cat "$BUILD_DIR/codex-desktop-cache/version.txt" 2>/dev/null || echo 'unknown')"
        echo "hostname=$(hostname)"
        echo "builder=$(whoami)"
    } > "$OUTPUT_DIR/build-info.txt"

    ok "Build complete!"
}

# ── Create USB raw image ─────────────────────────────────────────────────────
create_usb_image() {
    local iso="$1"
    local img="${iso%.iso}.img"

    step "Creating USB raw image"

    # Get ISO size and add padding
    local iso_size
    iso_size="$(stat -c%s "$iso")"
    local img_size=$((iso_size + 1073741824))  # Add 1GB for persistence

    log "Creating ${img_size} byte image..."
    dd if=/dev/zero of="$img" bs=1M count=$((img_size / 1048576)) status=progress

    # Partition the image
    log "Partitioning..."
    parted -s "$img" -- \
        mklabel gpt \
        mkpart primary fat32 1MiB $((iso_size / 1048576 + 1))MiB \
        set 1 boot on \
        set 1 esp on \
        mkpart primary ext4 $((iso_size / 1048576 + 1))MiB 100%

    # Copy ISO content to first partition
    log "Writing ISO to first partition..."
    local loop
    loop="$(losetup -f --show "$img")"
    partprobe "$loop" 2>/dev/null || true

    # Mount first partition and copy ISO
    local mntpnt
    mntpnt="$(mktemp -d)"
    mount "${loop}p1" "$mntpnt"

    # Extract ISO
    local iso_mntpnt
    iso_mntpnt="$(mktemp -d)"
    mount -o loop "$iso" "$iso_mntpnt"
    cp -a "$iso_mntpnt"/. "$mntpnt"/
    umount "$iso_mntpnt"
    rmdir "$iso_mntpnt"

    # Install GRUB
    grub-install --target=x86_64-efi --efi-directory="$mntpnt" \
        --boot-directory="$mntpnt/boot" --removable --no-nvram "$loop" 2>/dev/null || true

    umount "$mntpnt"
    rmdir "$mntpnt"
    losetup -d "$loop"

    # Compress
    log "Compressing image..."
    gzip -1 "$img"

    ok "USB image: ${img}.gz ($(du -h "${img}.gz" | cut -f1))"
}

# ── Test in QEMU ─────────────────────────────────────────────────────────────
do_test() {
    step "Testing in QEMU"

    local iso
    iso="$(find "$OUTPUT_DIR" -name '*.iso' -type f 2>/dev/null | sort -r | head -1)"

    if [ -z "$iso" ]; then
        err "No ISO found for testing"
        return 1
    fi

    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        warn "QEMU not installed. Skipping test."
        warn "Install: sudo apt-get install qemu-system-x86 qemu-utils"
        return 0
    fi

    log "Launching QEMU with: $iso"
    log "Close the QEMU window to exit test mode."

    qemu-system-x86_64 \
        -m 2048 \
        -smp 2 \
        -cdrom "$iso" \
        -boot d \
        -display gtk \
        -net nic \
        -net user \
        -usb \
        -device qemu-xhci \
        -enable-kvm 2>/dev/null \
        || {
        # Without KVM
        qemu-system-x86_64 \
            -m 2048 \
            -smp 1 \
            -cdrom "$iso" \
            -boot d \
            -display gtk \
            -net nic \
            -net user 2>/dev/null || {
            warn "QEMU test failed"
        }
    }
}

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║       CoLinux Desktop — Build Summary        ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║                                              ║"

    local iso
    iso="$(find "$OUTPUT_DIR" -name '*.iso' -type f 2>/dev/null | sort -r | head -1)"

    if [ -n "$iso" ]; then
        printf "║ ISO:     %-35s║\n" "$(basename "$iso")"
        printf "║ Size:    %-35s║\n" "$(du -h "$iso" | cut -f1)"
    else
        printf "║ %-45s║\n" "No ISO found"
    fi

    echo "║                                              ║"
    printf "║ Output:  %-35s║\n" "$OUTPUT_DIR"
    echo "║                                              ║"
    echo "║ To write to USB:                             ║"
    echo "║   sudo dd if=<iso> of=/dev/sdX bs=4M        ║"
    echo "║   status=progress && sync                    ║"
    echo "║                                              ║"
    echo "║ To test in QEMU:                             ║"
    echo "║   qemu-system-x86_64 -m 2048 -cdrom <iso>   ║"
    echo "╚══════════════════════════════════════════════╝"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║       CoLinux Desktop — Build System         ║"
    echo "║       Debian + XFCE4 + Electron Codex        ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""

    if $CLEAN_ONLY; then
        do_clean
        exit 0
    fi

    check_prerequisites

    if $FORCE; then
        do_clean
    fi

    setup_build_dir
    download_codex_desktop
    configure_lb
    do_build

    if $RUN_TEST; then
        do_test
    fi

    print_summary
}

main "$@"
