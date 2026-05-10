#!/usr/bin/env bash
# =============================================================================
# CoLinux Compat — Debian ISO Build Script
# =============================================================================
# Builds a bootable Debian minimal (bookworm) ISO with Codex CLI, TTY only.
# Uses debootstrap for rootfs creation and live-build for ISO generation.
#
# Prerequisites:  Run on a Debian system (or Docker container).
#                 Requires root/sudo for debootstrap and image mounting.
#
# Usage:
#   sudo ./build-debian-compat.sh [--arch amd64] [--suite bookworm] [--outdir ./out]
#
# Environment variables:
#   CODEX_VERSION   — Override Codex CLI version (default: latest)
#   DEBIAN_MIRROR   — Debian package mirror URL
#   COLINUX_IMG_SIZE— Image size in MB (default: 1200)
# =============================================================================
set -euo pipefail

# ── Cleanup ──────────────────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]+"${_CLEANUP_DIRS[@]}"}"; do
        rm -rf "$d" 2>/dev/null || true
    done
    # Unmount any leftover mounts
    umount /tmp/colinux-compat-build/chroot/proc 2>/dev/null || true
    umount /tmp/colinux-compat-build/chroot/sys 2>/dev/null || true
    umount /tmp/colinux-compat-build/chroot/dev 2>/dev/null || true
    umount /tmp/colinux-compat-build/chroot/run 2>/dev/null || true
}
trap _cleanup EXIT

# ── Defaults ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_DIR="$PROJECT_ROOT/profiles/debian-compat"
SHARED_DIR="$PROJECT_ROOT/shared"
OVERLAY_DIR="$PROFILE_DIR/overlay"
PACKAGE_LIST="$PROFILE_DIR/packages.compat"

ARCH="${ARCH:-amd64}"
SUITE="${SUITE:-bookworm}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
DEBIAN_SECURITY="${DEBIAN_SECURITY:-http://security.debian.org/debian-security}"
OUTDIR="${OUTDIR:-$PROJECT_ROOT/dist}"
CODEX_VERSION="${CODEX_VERSION:-latest}"
COLINUX_IMG_SIZE="${COLINUX_IMG_SIZE:-1200}"
BUILD_DIR="/tmp/colinux-compat-build"

# ── Colors (for TTY) ─────────────────────────────────────────────────────────
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

get_latest_codex_version() {
    curl -fsSL https://api.github.com/repos/openai/codex/releases/latest \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' \
        | head -1
}

get_codex_asset_digest_sha256() {
    local version="$1" asset_name="$2"
    curl -fsSL "https://api.github.com/repos/openai/codex/releases/tags/${version}" \
        | awk -v name="$asset_name" '
            index($0, "\"name\": \"" name "\"") { found=1 }
            found && /"digest":/ {
                sub(/^.*"digest": "sha256:/, "")
                sub(/".*$/, "")
                print
                exit
            }
        ' \
        | grep -E '^[0-9a-fA-F]{64}$' \
        | head -1
}

verify_codex_archive_digest() {
    local archive="$1" version="$2" asset_name="$3"
    local expected actual
    expected="$(get_codex_asset_digest_sha256 "$version" "$asset_name" || true)"
    if [ -z "$expected" ]; then
        log_error "Could not obtain SHA256 digest for $asset_name; refusing to install."
        exit 1
    fi
    actual="$(sha256sum "$archive" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        log_error "SHA256 mismatch for $asset_name."
        log_error "Expected: $expected"
        log_error "Actual:   $actual"
        exit 1
    fi
    log_info "SHA256 digest verified for $asset_name."
}


# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)       ARCH="$2"; shift 2 ;;
        --suite)      SUITE="$2"; shift 2 ;;
        --outdir)     OUTDIR="$2"; shift 2 ;;
        --codex-ver)  CODEX_VERSION="$2"; shift 2 ;;
        --img-size)   COLINUX_IMG_SIZE="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--arch amd64] [--suite bookworm] [--outdir DIR] [--img-size MB]"
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

check_arch() {
    case "$ARCH" in
        amd64|i386) ;;
        *) log_error "Unsupported architecture: $ARCH (use amd64 or i386)"; exit 1 ;;
    esac
}

# ── Step 1: Install build dependencies ───────────────────────────────────────
install_build_deps() {
    log_step "Installing build dependencies"

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y --no-install-recommends \
            debootstrap \
            squashfs-tools \
            xorriso \
            grub-efi-amd64-bin \
            grub-efi-ia32-bin \
            grub-pc-bin \
            mtools \
            dosfstools \
            fdisk \
            gdisk \
            bash \
            curl \
            ca-certificates \
            git \
            qemu-utils \
            openssl \
            cpio \
            isolinux \
            syslinux-common \
            live-build \
            xorriso
    else
        log_error "This build script requires a Debian-based host with apt-get."
        exit 1
    fi

    log_info "Build dependencies installed."
}

# ── Step 2: Bootstrap Debian rootfs ─────────────────────────────────────────
bootstrap_rootfs() {
    log_step "Bootstrapping Debian $SUITE rootfs for $ARCH"

    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR/chroot"
    _CLEANUP_DIRS+=("$BUILD_DIR")

    # Keyring setup for bookworm+
    if [[ "$SUITE" == "bookworm" || "$SUITE" == "trixie" || "$SUITE" == "sid" ]]; then
        debootstrap --arch="$ARCH" --variant=minbase "$SUITE" "$BUILD_DIR/chroot" "$DEBIAN_MIRROR"
    else
        debootstrap --arch="$ARCH" "$SUITE" "$BUILD_DIR/chroot" "$DEBIAN_MIRROR"
    fi

    log_info "Rootfs bootstrapped."
}

# ── Step 3: Configure chroot ─────────────────────────────────────────────────
configure_chroot() {
    log_step "Configuring chroot environment"

    local chroot="$BUILD_DIR/chroot"

    # Mount essential filesystems
    mount -t proc none "$chroot/proc"
    mount -t sysfs none "$chroot/sys"
    mount --bind /dev "$chroot/dev"
    mount --bind /run "$chroot/run"

    # Set hostname
    echo "colinux-compat" > "$chroot/etc/hostname"

    # Set up apt sources
    cat > "$chroot/etc/apt/sources.list" <<EOF
deb $DEBIAN_MIRROR $SUITE main contrib non-free non-free-firmware
deb $DEBIAN_MIRROR $SUITE-updates main contrib non-free non-free-firmware
deb $DEBIAN_SECURITY $SUITE-security main contrib non-free non-free-firmware
EOF

    # Set locale
    cat > "$chroot/etc/locale.conf" <<EOF
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
EOF
    chroot "$chroot" locale-gen en_US.UTF-8 2>/dev/null || true

    # Set timezone
    chroot "$chroot" ln -sf /usr/share/zoneinfo/UTC /etc/localtime

    # Configure keyboard
    cat > "$chroot/etc/default/keyboard" <<EOF
XKBMODEL=pc105
XKBLAYOUT=us
XKBVARIANT=
XKBOPTIONS=
EOF

    log_info "Chroot configured."
}

# ── Step 4: Install packages ─────────────────────────────────────────────────
install_packages() {
    log_step "Installing packages from packages.compat"

    local chroot="$BUILD_DIR/chroot"

    # Update package lists
    chroot "$chroot" apt-get update

    # Read package list and install (skip comments and blank lines)
    local packages
    packages=$(grep -v '^\s*#' "$PACKAGE_LIST" | grep -v '^\s*$' | tr '\n' ' ')

    log_info "Installing $(echo "$packages" | wc -w) packages..."

    # Set DEBIAN_FRONTEND to avoid interactive prompts
    chroot "$chroot" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        $packages

    log_info "Packages installed."
}

# ── Step 5: Create codex user ────────────────────────────────────────────────
create_user() {
    log_step "Creating codex user"

    local chroot="$BUILD_DIR/chroot"

    # Create codex user with consistent uid/gid
    chroot "$chroot" groupadd -g 1000 codex 2>/dev/null || true
    chroot "$chroot" useradd -m -u 1000 -g 1000 -s /bin/bash -d /home/codex codex 2>/dev/null || true

    # Set up codex user groups
    for grp in cdrom floppy audio dip video plugdev netdev; do
        chroot "$chroot" groupadd -r "$grp" 2>/dev/null || true
        chroot "$chroot" usermod -aG "$grp" codex 2>/dev/null || true
    done

    log_info "User codex created."
}

# ── Step 6: Copy overlay ─────────────────────────────────────────────────────
copy_overlay() {
    log_step "Copying overlay files"

    local chroot="$BUILD_DIR/chroot"

    if [[ -d "$OVERLAY_DIR" ]]; then
        # Copy overlay preserving structure
        cp -a "$OVERLAY_DIR"/. "$chroot"/

        # Fix permissions
        chown -R root:root "$chroot/etc" "$chroot/usr"
        chmod 755 "$chroot/home/codex"
        chown -R 1000:1000 "$chroot/home/codex"

        # Ensure scripts are executable
        find "$chroot/usr/local/bin" -type f -name 'codex-*' -exec chmod 755 {} \;
        find "$chroot/usr/local/sbin" -type f -exec chmod 755 {} \;

        log_info "Overlay copied."
    else
        log_warn "Overlay directory not found: $OVERLAY_DIR"
    fi
}

# ── Step 7: Install shared infrastructure ────────────────────────────────────
install_shared() {
    log_step "Installing shared infrastructure"

    local chroot="$BUILD_DIR/chroot"

    if [[ -x "$SHARED_DIR/install-shared.sh" ]]; then
        "$SHARED_DIR/install-shared.sh" \
            --edition compat \
            --dest "$chroot" \
            --distro debian \
            --verbose

        log_info "Shared infrastructure installed."
    else
        log_warn "Shared installer not found: $SHARED_DIR/install-shared.sh"
    fi
}

# ── Step 8: Download and inject Codex CLI ────────────────────────────────────
inject_codex() {
    log_step "Downloading and injecting Codex CLI"

    local chroot="$BUILD_DIR/chroot"

    local codex_arch codex_filename codex_tag
    case "$ARCH" in
        amd64)
            codex_arch="x86_64-unknown-linux-musl"
            codex_filename="codex-${codex_arch}.tar.gz"
            ;;
        i386)
            log_warn "OpenAI Codex does not publish i386 Linux binaries; will install on first boot if available."
            return 0
            ;;
    esac

    local download_url
    if [ "$CODEX_VERSION" = "latest" ]; then
        codex_tag="$(get_latest_codex_version)"
    else
        codex_tag="$CODEX_VERSION"
    fi
    if [ -z "$codex_tag" ]; then
        log_warn "Could not resolve Codex release tag. Will install on first boot."
        return 0
    fi
    download_url="https://github.com/openai/codex/releases/download/${codex_tag}/${codex_filename}"

    log_info "Downloading Codex CLI from: $download_url"

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    if curl -fsSL --retry 3 --retry-delay 5 -o "$tmpdir/$codex_filename" "$download_url" 2>/dev/null; then
        verify_codex_archive_digest "$tmpdir/$codex_filename" "$codex_tag" "$codex_filename"
        tar xzf "$tmpdir/$codex_filename" -C "$tmpdir" 2>/dev/null || true
        local codex_bin
        codex_bin="$(find "$tmpdir" -name "codex-${codex_arch}" -type f -executable | head -1)"
        if [[ -z "$codex_bin" ]]; then
            codex_bin="$(find "$tmpdir" -name 'codex' -type f -executable | head -1)"
        fi
        if [[ -n "$codex_bin" ]]; then
            cp "$codex_bin" "$chroot/usr/local/bin/codex"
            chmod 755 "$chroot/usr/local/bin/codex"
            log_info "Codex CLI installed to $chroot/usr/local/bin/codex"
        else
            log_warn "Could not find codex binary in archive. Will install on first boot."
        fi
    else
        log_warn "Failed to download Codex CLI. Will install on first boot."
    fi

    # Copy helper scripts
    for script in first-boot setup-codex cron-codex-update; do
        local src="$PROJECT_ROOT/scripts/${script}.sh"
        if [[ -f "$src" ]]; then
            cp "$src" "$chroot/usr/local/bin/${script}"
            chmod 755 "$chroot/usr/local/bin/${script}"
        fi
    done

    # Copy AGENTS.md
    mkdir -p "$chroot/workspace"
    if [[ -f "$PROJECT_ROOT/AGENTS.md" ]]; then
        cp "$PROJECT_ROOT/AGENTS.md" "$chroot/workspace/AGENTS.md"
    fi
}

# ── Step 9: Enable systemd services ──────────────────────────────────────────
enable_services() {
    log_step "Enabling systemd services"

    local chroot="$BUILD_DIR/chroot"

    chroot "$chroot" systemctl enable codex-network.service 2>/dev/null || true
    chroot "$chroot" systemctl enable codex-firstboot.service 2>/dev/null || true
    chroot "$chroot" systemctl enable codex-disk-inventory.service 2>/dev/null || true
    chroot "$chroot" systemctl enable codex-auto-update.timer 2>/dev/null || true
    chroot "$chroot" systemctl enable NetworkManager.service 2>/dev/null || true
    chroot "$chroot" systemctl enable systemd-resolved.service 2>/dev/null || true

    log_info "Systemd services enabled."
}

# ── Step 10: Clean up chroot ─────────────────────────────────────────────────
cleanup_chroot() {
    log_step "Cleaning up chroot"

    local chroot="$BUILD_DIR/chroot"

    # Clear apt cache
    chroot "$chroot" apt-get clean
    chroot "$chroot" apt-get autoremove -y 2>/dev/null || true

    # Remove temporary files
    chroot "$chroot" rm -rf /tmp/* /var/tmp/* 2>/dev/null || true

    # Remove SSH host keys (will be regenerated on first boot)
    chroot "$chroot" rm -f /etc/ssh/ssh_host_*_key 2>/dev/null || true

    log_info "Chroot cleaned."
}

# ── Step 11: Unmount chroot ──────────────────────────────────────────────────
unmount_chroot() {
    log_step "Unmounting chroot"

    local chroot="$BUILD_DIR/chroot"

    umount "$chroot/run" 2>/dev/null || true
    umount "$chroot/dev" 2>/dev/null || true
    umount "$chroot/sys" 2>/dev/null || true
    umount "$chroot/proc" 2>/dev/null || true

    log_info "Chroot unmounted."
}

# ── Step 12: Create squashfs ─────────────────────────────────────────────────
create_squashfs() {
    log_step "Creating squashfs root filesystem"

    local chroot="$BUILD_DIR/chroot"
    local squashfs="$BUILD_DIR/rootfs.squashfs"

    mksquashfs "$chroot" "$squashfs" \
        -comp xz \
        -Xdict-size 1M \
        -noappend \
        -e proc sys dev run

    local size_mb
    size_mb=$(du -mh "$squashfs" | cut -f1)
    log_info "Squashfs created: $squashfs ($size_mb)"
}

# ── Step 13: Generate ISO ────────────────────────────────────────────────────
generate_iso() {
    log_step "Generating bootable ISO"

    mkdir -p "$OUTDIR"

    local iso_name="colinux-compat-${ARCH}-${SUITE}.iso"
    local iso_path="$OUTDIR/$iso_name"
    local squashfs="$BUILD_DIR/rootfs.squashfs"
    local iso_staging
    iso_staging="$(mktemp -d)"
    _CLEANUP_DIRS+=("$iso_staging")

    # Create ISO directory structure
    mkdir -p "$iso_staging/boot/grub"
    mkdir -p "$iso_staging/EFI/BOOT"
    mkdir -p "$iso_staging/live"

    # Copy squashfs
    cp "$squashfs" "$iso_staging/live/filesystem.squashfs"

    # Copy kernel and initrd from chroot
    local chroot="$BUILD_DIR/chroot"
    local kernel_initrd_dir="$chroot/boot"
    local f
    for f in "$kernel_initrd_dir"/vmlinuz*; do
        [ -f "$f" ] && cp "$f" "$iso_staging/boot/vmlinuz" 2>/dev/null || true
    done
    for f in "$kernel_initrd_dir"/initrd*; do
        [ -f "$f" ] && cp "$f" "$iso_staging/boot/initrd.img" 2>/dev/null || true
    done

    # Create GRUB configuration
    cat > "$iso_staging/boot/grub/grub.cfg" <<'GRUBCFG'
set default=0
set timeout=5

menuentry "CoLinux Compat (Debian)" {
    linux /boot/vmlinuz boot=live quiet splash
    initrd /boot/initrd.img
}

menuentry "CoLinux Compat (Debian) — Safe Mode" {
    linux /boot/vmlinuz boot=live nomodeset
    initrd /boot/initrd.img
}
GRUBCFG

    # Build the ISO with xorriso
    if command -v xorriso &>/dev/null; then
        xorriso -as mkisofs \
            -o "$iso_path" \
            -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
            -c boot/boot.cat \
            -b boot/grub/bios.img \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            -eltorito-alt-boot \
            -e boot/grub/efi.img \
            -no-emul-boot \
            -isohybrid-gpt-basdat \
            -V "COLINUX-COMPAT" \
            -joliet -rational-rock \
            "$iso_staging" 2>/dev/null || {
            log_warn "xorriso EFI build failed, falling back to basic ISO..."
            xorriso -as mkisofs \
                -o "$iso_path" \
                -R -J -V "COLINUX-COMPAT" \
                "$iso_staging" 2>/dev/null || {
                log_error "ISO creation failed."
                exit 1
            }
        }
    else
        log_error "xorriso not found. Cannot create ISO."
        exit 1
    fi

    # Generate checksum
    (cd "$OUTDIR" && sha256sum "$iso_name" > "${iso_name}.sha256")

    log_info "ISO created: $iso_path"
}

# ── Step 14: Create raw USB image ────────────────────────────────────────────
create_usb_image() {
    log_step "Creating raw USB disk image"

    local iso_file
    iso_file="$(find "$OUTDIR" -name 'colinux-compat-*.iso' | head -1)"
    if [[ -z "$iso_file" ]]; then
        log_warn "No ISO found, skipping raw image creation."
        return 0
    fi

    local raw_file="${iso_file%.iso}.raw.img"
    local size_mb="$COLINUX_IMG_SIZE"

    log_info "Creating ${size_mb}MB raw disk image..."

    dd if=/dev/zero of="$raw_file" bs=1M count="$size_mb" status=progress

    # Create GPT partition table
    sfdisk "$raw_file" <<EOF
label: gpt
unit: sectors

start=2048,  size=65536,  type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="codex-efi"
start=67584, size=*,      type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="codex-boot"
EOF

    # Set up loop device
    local loop_dev
    loop_dev="$(losetup --find --show --partscan "$raw_file")"

    # Format partitions
    mkfs.vfat -F 32 -n "CODEX-EFI" "${loop_dev}p1"
    mkfs.ext4 -L "codex-boot" -q "${loop_dev}p2"

    # Mount and copy ISO contents
    local boot_mount iso_mount
    boot_mount="$(mktemp -d)"
    iso_mount="$(mktemp -d)"

    mount "${loop_dev}p2" "$boot_mount"
    mount -o loop "$iso_file" "$iso_mount"

    cp -a "$iso_mount"/. "$boot_mount"/
    sync

    umount "$iso_mount"
    umount "$boot_mount"
    rmdir "$iso_mount" "$boot_mount"

    # Install GRUB to ESP
    local esp_mount
    esp_mount="$(mktemp -d)"
    mount "${loop_dev}p1" "$esp_mount"

    mkdir -p "$esp_mount/EFI/BOOT"
    case "$ARCH" in
        amd64)
            grub-install --target=x86_64-efi \
                --efi-directory="$esp_mount" \
                --boot-directory="$boot_mount/boot" \
                --removable \
                --no-nvram \
                "$loop_dev" 2>/dev/null || \
            log_warn "grub-install failed (may work on bare metal)"
            ;;
        i386)
            grub-install --target=i386-efi \
                --efi-directory="$esp_mount" \
                --boot-directory="$boot_mount/boot" \
                --removable \
                --no-nvram \
                "$loop_dev" 2>/dev/null || \
            log_warn "grub-install failed (may work on bare metal)"
            ;;
    esac

    sync
    umount "$esp_mount"
    rmdir "$esp_mount"
    losetup -d "$loop_dev"

    log_info "Raw USB image created: $raw_file"
}

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
    log_step "Build Complete — CoLinux Compat"

    echo ""
    echo "  Edition:       CoLinux Compat (Debian GNU/Linux, TTY)"
    echo "  Architecture:  $ARCH"
    echo "  Suite:         $SUITE"
    echo "  Output:        $OUTDIR"
    echo ""
    find "$OUTDIR" -maxdepth 1 -type f \( -name '*.iso' -o -name '*.raw.img' -o -name '*.sha256' \) \
        -exec ls -lh {} \;
    echo ""
    log_info "To write to USB: sudo dd if=<raw.img> of=/dev/sdX bs=4M status=progress"
    log_info "To test in QEMU:  qemu-system-x86_64 -m 2048 -cdrom <iso>"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    log_step "CoLinux Compat Build — $ARCH / Debian $SUITE"

    check_root
    check_arch
    install_build_deps
    bootstrap_rootfs
    configure_chroot
    install_packages
    create_user
    copy_overlay
    install_shared
    inject_codex
    enable_services
    cleanup_chroot
    unmount_chroot
    create_squashfs
    generate_iso
    create_usb_image
    print_summary
}

main "$@"
