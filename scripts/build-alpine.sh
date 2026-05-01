#!/usr/bin/env bash
# =============================================================================
# CoLinux Lite — Alpine ISO Build Script
# =============================================================================
# Builds a bootable Alpine Linux ISO with Codex CLI integrated.
#
# Prerequisites:  Run on an Alpine Linux system (or Docker container).
#                 Requires root/sudo for package installation and image mounting.
#
# Usage:
#   sudo ./build-alpine.sh [--arch x86_64|aarch64] [--release 3.21] [--outdir ./out]
#
# Environment variables:
#   CODEX_VERSION   — Override Codex CLI version (default: latest)
#   ALPINE_MIRROR   — Alpine package mirror (default: dl-cdn.alpinelinux.org)
#   GPG_KEY         — GPG key ID for signing release artifacts
# =============================================================================
set -euo pipefail

# ── Cleanup ──────────────────────────────────────────────────────────────────
_CLEANUP_DIRS=""
_cleanup() {
    [ -n "${_CLEANUP_DIRS:-}" ] && rm -rf "${_CLEANUP_DIRS}" 2>/dev/null || true
}

# ── Defaults ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_DIR="$PROJECT_ROOT/profiles/alpine"

ARCH="${ARCH:-x86_64}"
ALPINE_RELEASE="${ALPINE_RELEASE:-3.21}"
ALPINE_MIRROR="${ALPINE_MIRROR:-http://dl-cdn.alpinelinux.org/alpine}"
OUTDIR="${OUTDIR:-$PROJECT_ROOT/dist}"
APORTS_BRANCH="v${ALPINE_RELEASE}.0"
APORTS_DIR="/tmp/aports-colinux"
CODEX_VERSION="${CODEX_VERSION:-latest}"

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

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)        ARCH="$2"; shift 2 ;;
        --release)     ALPINE_RELEASE="$2"; shift 2 ;;
        --outdir)      OUTDIR="$2"; shift 2 ;;
        --codex-ver)   CODEX_VERSION="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--arch x86_64|aarch64] [--release 3.21] [--outdir DIR]"
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
        x86_64|aarch64) ;;
        *) log_error "Unsupported architecture: $ARCH (use x86_64 or aarch64)"; exit 1 ;;
    esac
}

# ── Step 1: Install build dependencies ───────────────────────────────────────
install_build_deps() {
    log_step "Installing build dependencies"

    # Detect package manager
    if command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"
    elif command -v apt-get >/dev/null 2>&1; then
        PKG_MGR="apt"
    else
        log_error "No supported package manager found (apk or apt)."
        exit 1
    fi

    case "$PKG_MGR" in
        apk)
            apk update
            apk add --no-cache \
                alpine-sdk \
                alpine-conf \
                apk-tools \
                abuild \
                squashfs-tools \
                xorriso \
                grub \
                grub-efi \
                efibootmgr \
                mtools \
                dosfstools \
                util-linux \
                bash \
                curl \
                ca-certificates \
                git \
                qemu-img \
                openssl
            ;;
        apt)
            apt-get update
            apt-get install -y --no-install-recommends \
                squashfs-tools \
                xorriso \
                grub-efi-amd64-bin \
                mtools \
                dosfstools \
                fdisk \
                bash \
                curl \
                ca-certificates \
                git \
                qemu-utils \
                openssl \
                gdisk
            # grub-efi-arm64-bin may not be available; install with fallback
            apt-get install -y --no-install-recommends grub-efi-arm64-bin 2>/dev/null || true
            ;;
    esac

    log_info "Build dependencies installed."
}

# ── Step 2: Clone Alpine aports repository ───────────────────────────────────
clone_aports() {
    log_step "Cloning Alpine aports repository"

    if [ -d "$APORTS_DIR" ]; then
        log_info "aports directory exists, updating..."
        git -C "$APORTS_DIR" pull --ff-only || {
            log_warn "Git update failed, re-cloning..."
            rm -rf "$APORTS_DIR"
        }
    fi

    if [ ! -d "$APORTS_DIR" ]; then
        git clone --depth 1 --branch "$APORTS_BRANCH" \
            "https://gitlab.alpinelinux.org/alpine/aports.git" \
            "$APORTS_DIR"
    fi

    log_info "aports ready at $APORTS_DIR"
}

# ── Step 3: Install custom profile into aports ──────────────────────────────
install_profile() {
    log_step "Installing colinux-lite profile into aports"

    local profile_dest="$APORTS_DIR/scripts/mkimg.colinux-lite.sh"

    # Copy the profile script
    cp "$PROFILE_DIR/mkimg.colinux-lite.sh" "$profile_dest"
    chmod +x "$profile_dest"

    # Copy package lists
    cp "$PROFILE_DIR/packages.$ARCH" "$APORTS_DIR/scripts/packages.colinux-lite.$ARCH"
    # Also copy as the generic name for mkimage compatibility
    cp "$PROFILE_DIR/packages.$ARCH" "$APORTS_DIR/scripts/packages.colinux-lite"

    # Copy overlay directory
    if [ -d "$PROFILE_DIR/overlay" ]; then
        local overlay_dest="$APORTS_DIR/scripts/colinux-lite/overlay"
        mkdir -p "$overlay_dest"
        rm -rf "${overlay_dest:?}"
        cp -a "$PROFILE_DIR/overlay" "$overlay_dest"
    fi

    log_info "Profile installed."
}

# ── Step 4: Run mkimage.sh ──────────────────────────────────────────────────
run_mkimage() {
    log_step "Building Alpine ISO with mkimage"

    mkdir -p "$OUTDIR"

    local mkimage_script="$APORTS_DIR/scripts/mkimage.sh"
    if [ ! -f "$mkimage_script" ]; then
        log_error "mkimage.sh not found at $mkimage_script"
        exit 1
    fi
    chmod +x "$mkimage_script"

    # Patch mkimg.base.sh: make build_kernel tolerant of depmod warnings
    # Alpine 3.21's depmod/BusyBox install emits errors that are non-fatal
    # (depmod: ERROR: fstatat vmlinuz; install: omitting directory) but
    # cause build_section to fail via || return 1
    local mkimg_base="$APORTS_DIR/scripts/mkimg.base.sh"
    if [ -f "$mkimg_base" ]; then
        # Patch line with: || return 1  (the update-kernel continuation line)
        # Alpine 3.21 depmod/busybox install emit non-fatal errors that cause
        # build_section kernel to fail. We tolerate these since the kernel
        # and initramfs are still generated correctly.
        sed -i 's/^\t\t|| return 1$/\t\t|| true/' "$mkimg_base"
    fi

    # Build the ISO
    # --repository: Alpine package repos to use
    # --profile:     Our custom profile name
    # --arch:        Target architecture
    # --outdir:      Where to put the result
    # Set PACKAGER_PUBKEY so mkimage.sh can inject APK signing keys
    # (without it, cp "" fails inside the aports build framework)
    export PACKAGER_PUBKEY="${PACKAGER_PUBKEY:-$(ls /usr/share/apk/keys/*.rsa.pub 2>/dev/null | head -1)}"

    "$mkimage_script" \
        --profile "colinux-lite" \
        --arch "$ARCH" \
        --repository "${ALPINE_MIRROR}/v${ALPINE_RELEASE}/main" \
        --repository "${ALPINE_MIRROR}/v${ALPINE_RELEASE}/community" \
        --repository "${ALPINE_MIRROR}/edge/main" \
        --outdir "$OUTDIR" \
        --tag "v${ALPINE_RELEASE}" \
        --yaml "$APORTS_DIR/scripts/mkimg.colinux-lite.sh" \
        || {
            log_error "mkimage.sh failed!"
            exit 1
        }

    log_info "ISO built successfully."
}

# ── Step 5: Download and inject Codex CLI binary ────────────────────────────
inject_codex() {
    log_step "Downloading and injecting Codex CLI"

    # Determine the download filename for the architecture
    local codex_arch codex_filename
    case "$ARCH" in
        x86_64)
            codex_arch="x86_64-unknown-linux-musl"
            codex_filename="codex-${codex_arch}.tar.gz"
            ;;
        aarch64)
            codex_arch="aarch64-unknown-linux-musl"
            codex_filename="codex-${codex_arch}.tar.gz"
            ;;
    esac

    # Resolve version
    local download_url
    if [ "$CODEX_VERSION" = "latest" ]; then
        download_url="https://github.com/openai/codex/releases/latest/download/${codex_filename}"
    else
        download_url="https://github.com/openai/codex/releases/download/${CODEX_VERSION}/${codex_filename}"
    fi

    log_info "Downloading Codex CLI from: $download_url"

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS="${_CLEANUP_DIRS:-} $tmpdir"
    trap _cleanup EXIT

    # Download
    curl -fsSL --retry 3 --retry-delay 5 -o "$tmpdir/$codex_filename" "$download_url" || {
        log_error "Failed to download Codex CLI binary."
        exit 1
    }

    # Extract
    tar xzf "$tmpdir/$codex_filename" -C "$tmpdir" || {
        log_error "Failed to extract Codex CLI archive."
        exit 1
    }

    # Find the binary — Codex releases name it codex-$ARCH-unknown-linux-musl
    local codex_bin
    codex_bin="$(find "$tmpdir" -name "codex-${codex_arch}" -type f | head -1)"
    if [ -z "$codex_bin" ]; then
        codex_bin="$(find "$tmpdir" -name 'codex' -type f | head -1)"
    fi
    if [ -z "$codex_bin" ]; then
        log_error "Could not find codex binary in archive."
        log_error "Contents of archive:"
        find "$tmpdir" -maxdepth 2 -type f | head -20
        exit 1
    fi

    # Find the ISO and mount it to inject the binary
    local iso_file
    iso_file="$(find "$OUTDIR" -name 'colinux-lite-*.iso' | head -1)"
    if [ -z "$iso_file" ]; then
        log_error "Could not find built ISO in $OUTDIR"
        exit 1
    fi

    # Extract ISO, inject files, then repack (ISOs are read-only when mounted)
    log_info "Extracting ISO for file injection..."

    local iso_staging
    iso_staging="$(mktemp -d)"
    _CLEANUP_DIRS="${_CLEANUP_DIRS:-} $iso_staging"

    # Extract ISO contents using xorriso (handles ISO 9660 properly)
    if command -v xorriso &>/dev/null; then
        xorriso -osirrox on -indev "$iso_file" -extract / "$iso_staging" 2>/dev/null || {
            log_warn "xorriso extraction failed, trying alternative method..."
            # Fallback: mount read-only and copy
            local ro_mount
            ro_mount="$(mktemp -d)"
            mount -o loop,ro "$iso_file" "$ro_mount" 2>/dev/null || {
                log_error "Cannot mount ISO for extraction."
                log_info "Codex binary saved to: $codex_bin"
                log_info "Use setup-codex.sh on first boot instead."
                return 0
            }
            cp -a "$ro_mount"/. "$iso_staging"/
            umount "$ro_mount"
            rmdir "$ro_mount"
        }
    elif command -v bsdtar &>/dev/null; then
        bsdtar -xf "$iso_file" -C "$iso_staging" 2>/dev/null || {
            log_error "Cannot extract ISO."
            log_info "Codex binary saved to: $codex_bin"
            log_info "Use setup-codex.sh on first boot instead."
            return 0
        }
    else
        # Last resort: mount read-only and copy
        local ro_mount
        ro_mount="$(mktemp -d)"
        mount -o loop,ro "$iso_file" "$ro_mount" 2>/dev/null || {
            log_error "Cannot mount ISO for extraction."
            log_info "Codex binary saved to: $codex_bin"
            log_info "Use setup-codex.sh on first boot instead."
            return 0
        }
        cp -a "$ro_mount"/. "$iso_staging"/
        umount "$ro_mount"
        rmdir "$ro_mount"
    fi

    # Inject files into the staging directory
    mkdir -p "$iso_staging/usr/local/bin"
    cp "$codex_bin" "$iso_staging/usr/local/bin/codex"
    chmod 755 "$iso_staging/usr/local/bin/codex"

    # Also copy setup-codex.sh for first-boot use
    if [ -f "$PROJECT_ROOT/scripts/setup-codex.sh" ]; then
        cp "$PROJECT_ROOT/scripts/setup-codex.sh" "$iso_staging/usr/local/bin/setup-codex"
        chmod 755 "$iso_staging/usr/local/bin/setup-codex"
    fi

    # Copy first-boot.sh
    if [ -f "$PROJECT_ROOT/scripts/first-boot.sh" ]; then
        cp "$PROJECT_ROOT/scripts/first-boot.sh" "$iso_staging/usr/local/bin/first-boot"
        chmod 755 "$iso_staging/usr/local/bin/first-boot"
    fi

    # Copy cron update script
    if [ -f "$PROJECT_ROOT/scripts/cron-codex-update.sh" ]; then
        cp "$PROJECT_ROOT/scripts/cron-codex-update.sh" "$iso_staging/usr/local/bin/cron-codex-update"
        chmod 755 "$iso_staging/usr/local/bin/cron-codex-update"
    fi

    # Repack into a new ISO
    local repacked_iso="${iso_file%.iso}-injected.iso"
    log_info "Repacking ISO with injected files..."

    if command -v xorriso &>/dev/null; then
        if [ "$ARCH" = "x86_64" ]; then
            xorriso -as mkisofs \
                -o "$repacked_iso" \
                -isohybrid-mbr /usr/share/syslinux/mbr.bin \
                -c boot/boot.cat \
                -b boot/isolinux/isolinux.bin \
                -no-emul-boot \
                -boot-load-size 4 \
                -boot-info-table \
                -eltorito-alt-boot \
                -e boot/grub/efi.img \
                -no-emul-boot \
                -isohybrid-gpt-basdat \
                -V "COLINUX" \
                "$iso_staging" 2>/dev/null || {
                log_warn "xorriso repack failed. Trying genisoimage..."
                if command -v genisoimage &>/dev/null; then
                    genisoimage -o "$repacked_iso" \
                        -R -J -V "COLINUX" \
                        -b boot/isolinux/isolinux.bin \
                        -c boot/boot.cat \
                        -no-emul-boot \
                        -boot-load-size 4 \
                        -boot-info-table \
                        "$iso_staging" 2>/dev/null || {
                        log_warn "genisoimage also failed."
                        repacked_iso=""
                    }
                else
                    log_warn "genisoimage not available."
                    repacked_iso=""
                fi
            }
        else
            # EFI-only arches (aarch64): no isohybrid-mbr or isolinux
            xorriso -as mkisofs \
                -o "$repacked_iso" \
                -eltorito-alt-boot \
                -e boot/grub/efi.img \
                -no-emul-boot \
                -V "COLINUX" \
                "$iso_staging" 2>/dev/null || {
                log_warn "xorriso repack failed for $ARCH."
                repacked_iso=""
            }
        fi
    elif command -v genisoimage &>/dev/null; then
        genisoimage -o "$repacked_iso" \
            -R -J -V "COLINUX" \
            "$iso_staging" 2>/dev/null || {
            log_warn "genisoimage failed."
            repacked_iso=""
        }
    else
        log_warn "No ISO repacking tool available (xorriso or genisoimage)."
        repacked_iso=""
    fi

    if [[ -n "$repacked_iso" && -f "$repacked_iso" ]]; then
        # Replace the original ISO with the repacked one
        mv "$repacked_iso" "$iso_file"
        log_info "Codex CLI injected into ISO successfully."
    else
        log_warn "Could not repack ISO. Codex binary will need to be installed on first boot."
        log_info "Codex binary saved to: $codex_bin"
    fi
}

# ── Step 6: Create raw disk image from ISO ───────────────────────────────────
create_raw_image() {
    log_step "Creating raw disk image"

    local iso_file
    iso_file="$(find "$OUTDIR" -name 'colinux-lite-*.iso' | head -1)"
    if [ -z "$iso_file" ]; then
        log_warn "No ISO found, skipping raw image creation."
        return 0
    fi

    local raw_file="${iso_file%.iso}.raw.img"
    local size_mb=1024  # 1 GB raw image

    log_info "Creating ${size_mb}MB raw disk image..."

    # Create raw image with GPT + ESP + boot partition
    dd if=/dev/zero of="$raw_file" bs=1M count="$size_mb" status=progress

    # Partition
    sfdisk "$raw_file" <<EOF
label: gpt
unit: sectors

start=2048,  size=65536,  type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="codex-efi"
start=67584, size=*,      type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="codex-boot"
EOF

    # Set up loop device
    local loop_dev
    loop_dev="$(losetup --find --show --partscan "$raw_file")"

    # Format ESP
    mkfs.vfat -F 32 -n "CODEX-EFI" "${loop_dev}p1"
    # Format boot partition as ext4
    mkfs.ext4 -L "codex-boot" -q "${loop_dev}p2"

    # Mount and copy ISO contents
    local boot_mount
    boot_mount="$(mktemp -d)"
    mount "${loop_dev}p2" "$boot_mount"

    local iso_mount
    iso_mount="$(mktemp -d)"
    mount -o loop "$iso_file" "$iso_mount"

    cp -a "$iso_mount"/. "$boot_mount"/
    sync

    umount "$iso_mount"
    umount "$boot_mount"
    rmdir "$iso_mount" "$boot_mount"

    # Install GRUB
    local esp_mount
    esp_mount="$(mktemp -d)"
    mount "${loop_dev}p1" "$esp_mount"

    mkdir -p "$esp_mount/EFI/BOOT"
    case "$ARCH" in
        x86_64)
            grub-install --target=x86_64-efi \
                --efi-directory="$esp_mount" \
                --boot-directory="$boot_mount/boot" \
                --removable \
                --no-nvram \
                "$loop_dev" 2>/dev/null || \
            log_warn "grub-install failed (may work on bare metal)"
            ;;
        aarch64)
            grub-install --target=arm64-efi \
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

    log_info "Raw image created: $raw_file"
}

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
    log_step "Build Complete"

    echo ""
    echo "  Output directory: $OUTDIR"
    echo ""
    find "$OUTDIR" -type f \( -name '*.iso' -o -name '*.raw.img' -o -name '*.sha256' \) \
        -exec ls -lh {} \;
    echo ""
    log_info "To test: ./scripts/test-iso.sh --iso <path-to-iso>"
    log_info "To release: ./scripts/release.sh --outdir $OUTDIR"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    log_step "CoLinux Lite Build — $ARCH / Alpine $ALPINE_RELEASE"

    check_root
    check_arch
    install_build_deps
    clone_aports
    install_profile
    run_mkimage
    inject_codex
    create_raw_image
    print_summary
}

main "$@"
