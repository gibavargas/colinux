#!/usr/bin/env bash
# =============================================================================
# CodexOS Lite — Alpine ISO Build Script
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
    [ -n "${_CLEANUP_DIRS:-}" ] && rm -rf $_CLEANUP_DIRS 2>/dev/null || true
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
APORTS_DIR="/tmp/aports-codexos"
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
                jq \
                qemu-img \
                openssl
            ;;
        apt)
            apt-get update
            apt-get install -y --no-install-recommends \
                squashfs-tools \
                xorriso \
                grub-efi-amd64-bin \
                grub-efi-arm64-bin \
                mtools \
                dosfstools \
                fdisk \
                bash \
                curl \
                ca-certificates \
                git \
                jq \
                qemu-utils \
                openssl \
                gdisk
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
codex_arch_triple() {
    case "$ARCH" in
        x86_64)  echo "x86_64-unknown-linux-musl" ;;
        aarch64) echo "aarch64-unknown-linux-musl" ;;
        *) log_error "Unsupported Codex architecture: $ARCH"; exit 1 ;;
    esac
}

fetch_codex_release_json() {
    if [ "$CODEX_VERSION" = "latest" ]; then
        curl -fsSL "https://api.github.com/repos/openai/codex/releases/latest"
    else
        curl -fsSL "https://api.github.com/repos/openai/codex/releases/tags/${CODEX_VERSION}" 2>/dev/null || \
        curl -fsSL "https://api.github.com/repos/openai/codex/releases/tags/rust-v${CODEX_VERSION#v}"
    fi
}

download_codex_binary() {
    local dest="$1"
    local arch_triple filename release_json asset_info download_url digest expected_sha tmpdir binary

    arch_triple="$(codex_arch_triple)"
    filename="codex-${arch_triple}.tar.gz"
    release_json="$(fetch_codex_release_json)"
    asset_info="$(printf '%s\n' "$release_json" | jq -r --arg name "$filename" '
        .assets[]? | select(.name == $name) |
        [.browser_download_url, (.digest // "")] | @tsv
    ' | head -1)"

    if [ -z "$asset_info" ]; then
        log_error "Codex release does not contain required asset: $filename"
        exit 1
    fi

    download_url="$(printf '%s\n' "$asset_info" | cut -f1)"
    digest="$(printf '%s\n' "$asset_info" | cut -f2)"
    expected_sha="${digest#sha256:}"
    if [ -z "$expected_sha" ] || [ "$expected_sha" = "$digest" ]; then
        log_error "Codex release asset has no SHA-256 digest: $filename"
        exit 1
    fi

    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS="${_CLEANUP_DIRS:-} $tmpdir"
    trap _cleanup EXIT

    log_info "Downloading verified Codex asset: $filename"
    curl -fsSL --retry 3 --retry-delay 5 -o "$tmpdir/$filename" "$download_url"
    (cd "$tmpdir" && printf '%s  %s\n' "$expected_sha" "$filename" | sha256sum -c - >/dev/null)
    tar xzf "$tmpdir/$filename" -C "$tmpdir"
    binary="$(find "$tmpdir" \( -name "codex-${arch_triple}" -o -name codex \) -type f | head -1)"
    if [ -z "$binary" ]; then
        log_error "Could not find Codex binary in $filename"
        exit 1
    fi
    install -m 0755 "$binary" "$dest"
}

install_profile() {
    log_step "Installing codexos-lite profile into aports"

    local profile_dest="$APORTS_DIR/scripts/mkimg.codexos-lite.sh"

    # Copy the profile script
    cp "$PROFILE_DIR/mkimg.codexos-lite.sh" "$profile_dest"
    chmod +x "$profile_dest"

    # Copy package lists
    cp "$PROFILE_DIR/packages.$ARCH" "$APORTS_DIR/scripts/packages.codexos-lite.$ARCH"
    # Also copy as the generic name for mkimage compatibility
    cp "$PROFILE_DIR/packages.$ARCH" "$APORTS_DIR/scripts/packages.codexos-lite"

    # Copy overlay directory
    if [ -d "$PROFILE_DIR/overlay" ]; then
        local overlay_dest="$APORTS_DIR/scripts/codexos-lite/overlay"
        rm -rf "$overlay_dest"
        cp -a "$PROFILE_DIR/overlay" "$overlay_dest"

        mkdir -p "$overlay_dest/usr/local/bin" "$overlay_dest/usr/share/codexos"
        install -m 0755 "$PROJECT_ROOT/scripts/first-boot.sh" "$overlay_dest/usr/local/bin/first-boot"
        install -m 0755 "$PROJECT_ROOT/scripts/setup-codex.sh" "$overlay_dest/usr/local/bin/setup-codex"
        install -m 0755 "$PROJECT_ROOT/scripts/cron-codex-update.sh" "$overlay_dest/usr/local/bin/cron-codex-update"
        install -m 0644 "$PROJECT_ROOT/AGENTS.md" "$overlay_dest/usr/share/codexos/AGENTS.md"
        download_codex_binary "$overlay_dest/usr/local/bin/codex"
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

    # Build the ISO
    # --repository: Alpine package repos to use
    # --profile:     Our custom profile name
    # --arch:        Target architecture
    # --outdir:      Where to put the result
    "$mkimage_script" \
        --profile "codexos-lite" \
        --arch "$ARCH" \
        --repository "${ALPINE_MIRROR}/alpine/v${ALPINE_RELEASE}/main" \
        --repository "${ALPINE_MIRROR}/alpine/v${ALPINE_RELEASE}/community" \
        --outdir "$OUTDIR" \
        --extra-repository "${ALPINE_MIRROR}/alpine/edge/main" \
        --tag "v${ALPINE_RELEASE}" \
        --yaml "$APORTS_DIR/scripts/mkimg.codexos-lite.sh" \
        || {
            log_error "mkimage.sh failed!"
            exit 1
        }

    log_info "ISO built successfully."
}

# ── Step 5: Download and inject Codex CLI binary ────────────────────────────
inject_codex() {
    log_step "Codex CLI already staged in overlay"
    log_info "Skipping post-build ISO mutation; release assets are verified before mkimage runs."
}

# ── Step 6: Create raw disk image from ISO ───────────────────────────────────
create_raw_image() {
    log_step "Creating raw disk image"

    local iso_file
    iso_file="$(find "$OUTDIR" -name 'codexos-lite-*.iso' | head -1)"
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
    rmdir "$iso_mount"

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
    umount "$boot_mount"
    rmdir "$esp_mount"
    rmdir "$boot_mount"

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
    log_step "CodexOS Lite Build — $ARCH / Alpine $ALPINE_RELEASE"

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
