#!/usr/bin/env bash
# =============================================================================
# CoLinux Lite GUI — Alpine ISO Build Script
# =============================================================================
# Builds a bootable Alpine Linux ISO with Codex CLI + Wayland GUI (cage+foot).
#
# Prerequisites:  Run on an Alpine Linux system (or Docker container).
#                 Requires root/sudo for package installation and image mounting.
#
# Usage:
#   sudo ./build-alpine-gui.sh [--arch x86_64|aarch64] [--release 3.21] [--outdir ./out]
#
# Environment variables:
#   CODEX_VERSION   — Override Codex CLI version (default: latest)
#   ALPINE_MIRROR   — Alpine package mirror (default: dl-cdn.alpinelinux.org)
#   COLINUX_IMG_SIZE— Image size in MB (default: 900 for GUI edition)
#   GPG_KEY         — GPG key ID for signing release artifacts
# =============================================================================
set -euo pipefail

# ── Cleanup ──────────────────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() {
    if [[ ${#_CLEANUP_DIRS[@]} -gt 0 ]]; then
        rm -rf "${_CLEANUP_DIRS[@]}" 2>/dev/null || true
    fi
}

# ── Defaults ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_DIR="$PROJECT_ROOT/profiles/alpine"
SHARED_DIR="$PROJECT_ROOT/shared"

ARCH="${ARCH:-x86_64}"
ALPINE_RELEASE="${ALPINE_RELEASE:-3.21}"
ALPINE_MIRROR="${ALPINE_MIRROR:-http://dl-cdn.alpinelinux.org/alpine}"
OUTDIR="${OUTDIR:-$PROJECT_ROOT/dist}"
APORTS_BRANCH="v${ALPINE_RELEASE}.0"
APORTS_DIR="/tmp/aports-colinux-gui"
_CLEANUP_DIRS=("${_CLEANUP_DIRS[@]}" "$APORTS_DIR")
CODEX_VERSION="${CODEX_VERSION:-latest}"
COLINUX_IMG_SIZE="${COLINUX_IMG_SIZE:-900}"

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
        --arch)        ARCH="$2"; shift 2 ;;
        --release)     ALPINE_RELEASE="$2"; shift 2 ;;
        --outdir)      OUTDIR="$2"; shift 2 ;;
        --codex-ver)   CODEX_VERSION="$2"; shift 2 ;;
        --img-size)    COLINUX_IMG_SIZE="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--arch x86_64|aarch64] [--release 3.21] [--outdir DIR] [--img-size MB]"
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
            apt-get install -y --no-install-recommends grub-efi-arm64-bin || true
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
    log_step "Installing colinux-lite-gui profile into aports"

    local profile_dest="$APORTS_DIR/scripts/mkimg.colinux-lite-gui.sh"

    # Copy the profile script
    cp "$PROFILE_DIR/mkimg.colinux-lite-gui.sh" "$profile_dest"
    chmod +x "$profile_dest"

    # Copy GUI package lists
    local gui_pkg="$PROFILE_DIR/packages.${ARCH}.gui"
    if [[ ! -f "$gui_pkg" ]]; then
        log_error "GUI package list not found: $gui_pkg"
        exit 1
    fi

    cp "$gui_pkg" "$APORTS_DIR/scripts/packages.colinux-lite-gui.${ARCH}"
    cp "$gui_pkg" "$APORTS_DIR/scripts/packages.colinux-lite-gui"

    # Copy overlay directory
    if [ -d "$PROFILE_DIR/overlay-gui" ]; then
        local overlay_dest="$APORTS_DIR/scripts/colinux-lite-gui/overlay-gui"
        rm -rf "$overlay_dest"
        cp -a "$PROFILE_DIR/overlay-gui" "$overlay_dest"
    else
        log_error "GUI overlay directory not found: $PROFILE_DIR/overlay-gui"
        exit 1
    fi

    log_info "Profile installed."
}

# ── Step 4: Run shared infrastructure installer ─────────────────────────────
install_shared() {
    log_step "Installing shared infrastructure into overlay-gui"

    if [[ ! -x "$SHARED_DIR/install-shared.sh" ]]; then
        log_warn "Shared installer not found: $SHARED_DIR/install-shared.sh"
        return 0
    fi

    local overlay_dest="$APORTS_DIR/scripts/colinux-lite-gui/overlay-gui"

    "$SHARED_DIR/install-shared.sh" \
        --edition lite-gui \
        --dest "$overlay_dest" \
        --distro alpine \
        --verbose

    log_info "Shared infrastructure installed into overlay."
}

# ── Step 5: Run mkimage.sh ──────────────────────────────────────────────────
run_mkimage() {
    log_step "Building Alpine GUI ISO with mkimage"

    mkdir -p "$OUTDIR"

    local mkimage_script="$APORTS_DIR/scripts/mkimage.sh"
    if [ ! -f "$mkimage_script" ]; then
        log_error "mkimage.sh not found at $mkimage_script"
        exit 1
    fi
    chmod +x "$mkimage_script"

    export COLINUX_IMG_SIZE

    "$mkimage_script" \
        --profile "colinux-lite-gui" \
        --arch "$ARCH" \
        --repository "${ALPINE_MIRROR}/v${ALPINE_RELEASE}/main" \
        --repository "${ALPINE_MIRROR}/v${ALPINE_RELEASE}/community" \
        --outdir "$OUTDIR" \
        --tag "v${ALPINE_RELEASE}" \
        --yaml "$APORTS_DIR/scripts/mkimg.colinux-lite-gui.sh" \
        || {
            log_error "mkimage.sh failed!"
            exit 1
        }

    log_info "ISO built successfully."
}

# ── Step 6: Download and inject Codex CLI binary ────────────────────────────
inject_codex() {
    log_step "Downloading and injecting Codex CLI"

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

    # Resolve version to an immutable release tag so the downloaded asset can be verified.
    local codex_tag download_url
    if [ "$CODEX_VERSION" = "latest" ]; then
        codex_tag="$(get_latest_codex_version)"
    else
        codex_tag="$CODEX_VERSION"
    fi
    if [ -z "$codex_tag" ]; then
        log_error "Could not resolve Codex CLI release tag."
        exit 1
    fi
    download_url="https://github.com/openai/codex/releases/download/${codex_tag}/${codex_filename}"

    log_info "Downloading Codex CLI $codex_tag from: $download_url"

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS=("${_CLEANUP_DIRS[@]}" "$tmpdir")
    trap _cleanup EXIT

    curl -fsSL --retry 3 --retry-delay 5 -o "$tmpdir/$codex_filename" "$download_url" || {
        log_error "Failed to download Codex CLI binary."
        exit 1
    }
    verify_codex_archive_digest "$tmpdir/$codex_filename" "$codex_tag" "$codex_filename"

    tar xzf "$tmpdir/$codex_filename" -C "$tmpdir" || {
        log_error "Failed to extract Codex CLI archive."
        exit 1
    }

    local codex_bin
    codex_bin="$(find "$tmpdir" -name "codex-${codex_arch}" -type f -executable | head -1)"
    if [ -z "$codex_bin" ]; then
        codex_bin="$(find "$tmpdir" -name 'codex' -type f -executable | head -1)"
    fi
    if [ -z "$codex_bin" ]; then
        log_error "Could not find codex binary in archive."
        exit 1
    fi

    # Find the ISO
    local iso_file
    iso_file="$(find "$OUTDIR" -name 'colinux-lite-gui-*.iso' | head -1)"
    if [ -z "$iso_file" ]; then
        log_error "Could not find built ISO in $OUTDIR"
        exit 1
    fi

    # Extract ISO, inject files, then repack
    log_info "Extracting ISO for file injection..."

    local iso_staging
    iso_staging="$(mktemp -d)"
    _CLEANUP_DIRS=("${_CLEANUP_DIRS[@]}" "$iso_staging")

    if command -v xorriso &>/dev/null; then
        xorriso -osirrox on -indev "$iso_file" -extract / "$iso_staging" 2>/dev/null || {
            local ro_mount
            ro_mount="$(mktemp -d)"
            mount -o loop,ro "$iso_file" "$ro_mount" 2>/dev/null || {
                log_error "Cannot mount ISO for extraction."
                log_info "Codex binary saved to: $codex_bin"
                return 0
            }
            cp -a "$ro_mount"/. "$iso_staging"/
            umount "$ro_mount"
            rmdir "$ro_mount"
        }
    else
        local ro_mount
        ro_mount="$(mktemp -d)"
        mount -o loop,ro "$iso_file" "$ro_mount" 2>/dev/null || {
            log_error "Cannot mount ISO for extraction."
            log_info "Codex binary saved to: $codex_bin"
            return 0
        }
        cp -a "$ro_mount"/. "$iso_staging"/
        umount "$ro_mount"
        rmdir "$ro_mount"
    fi

    # Inject Codex CLI binary
    mkdir -p "$iso_staging/usr/local/bin"
    cp "$codex_bin" "$iso_staging/usr/local/bin/codex"
    chmod 755 "$iso_staging/usr/local/bin/codex"

    # Inject helper scripts
    for script in setup-codex first-boot cron-codex-update; do
        local src="$PROJECT_ROOT/scripts/${script}.sh"
        if [[ -f "$src" ]]; then
            cp "$src" "$iso_staging/usr/local/bin/${script}"
            chmod 755 "$iso_staging/usr/local/bin/${script}"
        fi
    done

    # Inject AGENTS.md into workspace
    mkdir -p "$iso_staging/workspace"
    if [[ -f "$PROJECT_ROOT/AGENTS.md" ]]; then
        cp "$PROJECT_ROOT/AGENTS.md" "$iso_staging/workspace/AGENTS.md"
    fi

    # Repack into ISO
    local repacked_iso="${iso_file%.iso}-injected.iso"
    log_info "Repacking ISO with injected files..."

    if command -v xorriso &>/dev/null; then
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
            -V "COLINUX-GUI" \
            "$iso_staging" 2>/dev/null || {
            log_warn "xorriso repack failed."
            repacked_iso=""
        }
    fi

    if [[ -n "$repacked_iso" && -f "$repacked_iso" ]]; then
        mv "$repacked_iso" "$iso_file"
        log_info "Codex CLI injected into ISO successfully."
    else
        log_warn "Could not repack ISO. Codex binary will be installed on first boot."
    fi
}

# ── Step 7: Create raw disk image from ISO ───────────────────────────────────
create_raw_image() {
    log_step "Creating raw disk image"

    local iso_file
    iso_file="$(find "$OUTDIR" -name 'colinux-lite-gui-*.iso' | head -1)"
    if [ -z "$iso_file" ]; then
        log_warn "No ISO found, skipping raw image creation."
        return 0
    fi

    local raw_file="${iso_file%.iso}.raw.img"
    local size_mb="${COLINUX_IMG_SIZE}"

    log_info "Creating ${size_mb}MB raw disk image..."

    dd if=/dev/zero of="$raw_file" bs=1M count="$size_mb" status=progress

    sfdisk "$raw_file" <<EOF
label: gpt
unit: sectors

start=2048,  size=65536,  type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="codex-efi"
start=67584, size=*,      type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="codex-boot"
EOF

    local loop_dev
    loop_dev="$(losetup --find --show --partscan "$raw_file")"

    mkfs.vfat -F 32 -n "CODEX-EFI" "${loop_dev}p1"
    mkfs.ext4 -L "codex-boot" -q "${loop_dev}p2"

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
    log_step "Build Complete — CoLinux Lite GUI"

    echo ""
    echo "  Edition:       CoLinux Lite GUI (cage + sway + foot)"
    echo "  Architecture:  $ARCH"
    echo "  Alpine:        $ALPINE_RELEASE"
    echo "  Output:        $OUTDIR"
    echo ""
    find "$OUTDIR" -type f \( -name '*.iso' -o -name '*.raw.img' -o -name '*.sha256' \) \
        -exec ls -lh {} \;
    echo ""
    log_info "To test: ./scripts/test-iso.sh --iso <path-to-iso>"
    log_info "To release: ./scripts/release.sh --outdir $OUTDIR"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    log_step "CoLinux Lite GUI Build — $ARCH / Alpine $ALPINE_RELEASE"

    check_root
    check_arch
    install_build_deps
    clone_aports
    install_profile
    install_shared
    run_mkimage
    inject_codex
    create_raw_image
    print_summary
}

main "$@"
