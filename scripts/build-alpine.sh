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
#   CODEX_VERSION      — Override Codex CLI version (default: latest)
#   ALPINE_MIRROR      — Alpine package mirror (default: dl-cdn.alpinelinux.org)
#   ALPINE_REPO_SNAPSHOT — Pin Alpine package repos to a frozen base URL (no
#                          trailing slash) for hermetic, reproducible builds.
#                          When set, repos resolve to <snapshot>/main and
#                          <snapshot>/community instead of the rolling
#                          v$ALPINE_RELEASE/* branches. Example:
#                          https://dl-cdn.alpinelinux.org/alpine/v3.21.0
#   GPG_KEY            — GPG key ID for signing release artifacts
# =============================================================================
set -euo pipefail

# ── Cleanup ──────────────────────────────────────────────────────────────────
_CLEANUP_DIRS=()
# Reproducibility state: populated by capture_repo_state() as "url=sha256" entries.
REPO_STATE=()
# Resolved Codex release tag (set by inject_codex, read by the manifest).
CODEX_RESOLVED_TAG=""
_cleanup() {
    if [ ${#_CLEANUP_DIRS[@]} -gt 0 ]; then
        rm -rf "${_CLEANUP_DIRS[@]}" 2>/dev/null || true
    fi
}

# ── Defaults ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_DIR="$PROJECT_ROOT/profiles/alpine"

ARCH="${ARCH:-x86_64}"
ALPINE_RELEASE="${ALPINE_RELEASE:-3.21}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
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

validate_tar_archive() {
    local archive="$1" member listing

    listing="$(tar tzf "$archive")" || {
        log_error "Failed to list archive contents."
        return 1
    }

    while IFS= read -r member; do
        case "$member" in
            ""|/*|../*|*/../*|*/..|..)
                log_error "Unsafe archive member path: $member"
                return 1
                ;;
        esac
    done <<< "$listing"

    if ! tar tvzf "$archive" | awk '{ type=substr($1,1,1); if (type == "l" || type == "h" || $0 ~ / link to / || $0 ~ / -> /) exit 1 }'; then
        log_error "Archive contains symlink or hardlink entries."
        return 1
    fi
}
log_step()  { echo -e "\n${BLUE}━━━ $* ━━━${NC}\n"; }

get_latest_codex_version() {
    curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors https://api.github.com/repos/openai/codex/releases/latest \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' \
        | head -1
}

get_codex_asset_digest_sha256() {
    local version="$1" asset_name="$2"
    curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors "https://api.github.com/repos/openai/codex/releases/tags/${version}" \
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
        local attempt max_attempts=3
        for attempt in $(seq 1 "$max_attempts"); do
            if git clone --depth 1 --branch "$APORTS_BRANCH" \
                "https://gitlab.alpinelinux.org/alpine/aports.git" \
                "$APORTS_DIR"; then
                break
            fi
            if [ "$attempt" -eq "$max_attempts" ]; then
                log_error "Failed to clone Alpine aports after $max_attempts attempts."
                exit 1
            fi
            log_warn "aports clone failed (attempt $attempt/$max_attempts); retrying..."
            rm -rf "$APORTS_DIR"
            sleep $((attempt * 5))
        done
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

        # Fix security-critical file permissions (cp -a preserves umask-inflated modes)
        [ -f "$overlay_dest/etc/doas.conf" ] && chmod 640 "$overlay_dest/etc/doas.conf"
        find "$overlay_dest/etc/sudoers.d" -type f -exec chmod 440 {} \; 2>/dev/null || true
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
    # --repository: Alpine package repos to use (built from repo_urls(); honors
    #               ALPINE_REPO_SNAPSHOT for hermetic, reproducible builds).
    # --profile:     Our custom profile name
    # --arch:        Target architecture
    # --outdir:      Where to put the result
    # Set PACKAGER_PUBKEY so mkimage.sh can inject APK signing keys
    # (without it, cp "" fails inside the aports build framework)
    export PACKAGER_PUBKEY="${PACKAGER_PUBKEY:-$(find /usr/share/apk/keys -maxdepth 1 -type f -name '*.rsa.pub' 2>/dev/null | sort | head -1)}"

    # The aports mkimage.sh calls git status to detect a -dirty suffix.
    # Inside the Docker container, git discovers the mounted /src/.git
    # (colinux repo) instead of the aports repo and fails.
    # alpine-sdk depends on git so `apk del` fails; move the binary instead.
    if command -v git >/dev/null 2>&1; then
        mv "$(command -v git)" /tmp/git.disabled || true
    fi

    # Assemble --repository flags from the resolved repo list.
    local repo_args=() repo
    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        repo_args+=(--repository "$repo")
    done < <(repo_urls)
    if [ "${#repo_args[@]}" -eq 0 ]; then
        log_error "No Alpine repositories configured."
        exit 1
    fi

    "$mkimage_script" \
        --profile "colinux-lite" \
        --arch "$ARCH" \
        "${repo_args[@]}" \
        --outdir "$OUTDIR" \
        --tag "v${ALPINE_RELEASE}" \
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
    # Expose the resolved immutable tag for the reproducibility manifest.
    CODEX_RESOLVED_TAG="$codex_tag"
    download_url="https://github.com/openai/codex/releases/download/${codex_tag}/${codex_filename}"

    log_info "Downloading Codex CLI $codex_tag from: $download_url"

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    trap _cleanup EXIT

    # Download and verify integrity using GitHub release asset digest.
    curl -fsSL --retry 3 --retry-delay 5 --retry-all-errors -o "$tmpdir/$codex_filename" "$download_url" || {
        log_error "Failed to download Codex CLI binary."
        exit 1
    }
    verify_codex_archive_digest "$tmpdir/$codex_filename" "$codex_tag" "$codex_filename"

    # Validate archive metadata before extraction, then extract.
    validate_tar_archive "$tmpdir/$codex_filename" || exit 1
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
    _CLEANUP_DIRS+=("$iso_staging")

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

    # Check if loop devices are available (Docker containers often lack /dev/loop*)
    # Try to create the primary loop device node if missing
    if [ ! -e /dev/loop0 ]; then
        # Attempt to create the loop device node (major 7, minor 0)
        mknod /dev/loop0 b 7 0 2>/dev/null || true
    fi
    # Verify losetup actually works before proceeding
    if ! losetup --find --show --partscan >/dev/null 2>&1; then
        log_warn "Loop devices are not available (common in Docker containers)."
        log_warn "Skipping raw disk image creation — the ISO is the critical artifact."
        return 0
    fi

    local raw_file="${iso_file%.iso}.raw.img"
    local size_mb=1024  # 1 GB raw image

    log_info "Creating ${size_mb}MB raw disk image..."

    # Create raw image with GPT + ESP + boot partition
    dd if=/dev/zero of="$raw_file" bs=1M count="$size_mb" 2>/dev/null

    # Partition
    sfdisk "$raw_file" <<EOF
label: gpt
unit: sectors

start=2048,  size=65536,  type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="codex-efi"
start=67584,  type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="codex-boot"
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

    cp -a "$iso_mount"/. "$boot_mount"/.
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

# ── Step 7: Reproducibility — repo pinning, checksums, manifest ─────────────

# Locate git even after run_mkimage moves it to /tmp/git.disabled (the aports
# mkimage.sh trips on the colinux .git, so the binary is hidden during build).
_git() {
    if [ -x /tmp/git.disabled ]; then
        /tmp/git.disabled "$@"
    elif command -v git >/dev/null 2>&1; then
        git "$@"
    else
        return 127
    fi
}

# Resolve the Alpine package repository URLs used by mkimage.
# When ALPINE_REPO_SNAPSHOT is set, all repos are pinned to that frozen base
# (e.g. https://dl-cdn.alpinelinux.org/alpine/v3.21.0) for hermetic builds.
# Otherwise the rolling v$ALPINE_RELEASE/* branches are used.
repo_urls() {
    local base
    if [ -n "${ALPINE_REPO_SNAPSHOT:-}" ]; then
        base="${ALPINE_REPO_SNAPSHOT%/}"
    else
        base="${ALPINE_MIRROR%/}/v${ALPINE_RELEASE}"
    fi
    echo "${base}/main"
    echo "${base}/community"
}

# Capture the SHA-256 of each repo's APKINDEX.tar.gz so the exact package set
# is recorded in the manifest. Non-fatal: offline builds record "unavailable".
# APKINDEX path: <repo>/<arch>/APKINDEX.tar.gz
capture_repo_state() {
    log_info "Capturing Alpine repository APKINDEX checksums"
    REPO_STATE=()
    local repo url sum
    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        url="${repo}/${ARCH}/APKINDEX.tar.gz"
        sum="$(curl -fsSL --retry 2 --retry-delay 2 --retry-all-errors "$url" 2>/dev/null \
            | sha256sum | awk '{print $1}')" || sum=""
        if [ -n "$sum" ]; then
            REPO_STATE+=("${url}=${sum}")
            log_info "  ${repo} -> ${sum}"
        else
            REPO_STATE+=("${url}=unavailable")
            log_warn "  ${repo} -> APKINDEX unavailable (offline build?)"
        fi
    done < <(repo_urls)
}

# Escape a string for safe inclusion in a JSON string literal (no jq needed).
_json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Generate SHA-256 checksums for the build artifacts (ISO + raw image).
# Local builds now get the same SHA256SUMS manifest CI produces.
generate_checksums() {
    log_step "Generating SHA-256 checksums for build artifacts"

    local sums="$OUTDIR/SHA256SUMS"
    (
        cd "$OUTDIR"
        : > "$sums"
        local f
        for f in colinux-lite-*.iso colinux-lite-*.raw.img; do
            [ -e "$f" ] || continue
            sha256sum "$f"
        done >> "$sums"
    )

    if [ -s "$sums" ]; then
        log_info "Wrote ${sums}"
        cat "$sums"
    else
        log_warn "No ISO/raw-image artifacts found to checksum."
    fi
}

# Write a reproducibility manifest (KEY=VALUE text + JSON) capturing every
# input that affects the build output, so two builds can be verified identical.
generate_build_manifest() {
    log_step "Generating reproducibility manifest"

    local aports_commit source_commit build_ts manifest_codex_tag
    aports_commit="$(_git -C "$APORTS_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    source_commit="$(_git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    build_ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    manifest_codex_tag="${CODEX_RESOLVED_TAG:-$CODEX_VERSION}"
    local build_host build_kernel
    build_host="$(uname -n 2>/dev/null || echo unknown)"
    build_kernel="$(uname -r 2>/dev/null || echo unknown)"

    # ── KEY=VALUE text manifest (primary, dependency-free) ──
    local manifest_txt="$OUTDIR/build-manifest.txt"
    {
        echo "# CoLinux Lite — reproducibility manifest"
        echo "# Reproduce by pinning the same inputs (aports commit, codex tag,"
        echo "# repo snapshot). Compare SHA256SUMS across two builds to verify."
        echo "build_timestamp=${build_ts}"
        echo "edition=colinux-lite"
        echo "arch=${ARCH}"
        echo "alpine_release=${ALPINE_RELEASE}"
        echo "aports_branch=${APORTS_BRANCH}"
        echo "aports_commit=${aports_commit}"
        echo "codex_tag=${manifest_codex_tag}"
        echo "alpine_mirror=${ALPINE_MIRROR}"
        echo "alpine_repo_snapshot=${ALPINE_REPO_SNAPSHOT:-}"
        echo "source_commit=${source_commit}"
        echo "build_host=${build_host}"
        echo "build_kernel=${build_kernel}"
        echo ""
        echo "# Alpine repository APKINDEX checksums (<url>=<sha256|unavailable>)"
        local entry
        for entry in "${REPO_STATE[@]}"; do
            echo "repo_apkindex=${entry}"
        done
    } > "$manifest_txt"
    log_info "Wrote ${manifest_txt}"

    # ── JSON variant (portable; no jq dependency) ──
    local manifest_json="$OUTDIR/build-manifest.json"
    {
        echo "{"
        echo "  \"edition\": \"colinux-lite\","
        echo "  \"build_timestamp\": \"$(_json_escape "$build_ts")\","
        echo "  \"arch\": \"$(_json_escape "$ARCH")\","
        echo "  \"alpine_release\": \"$(_json_escape "$ALPINE_RELEASE")\","
        echo "  \"aports_branch\": \"$(_json_escape "$APORTS_BRANCH")\","
        echo "  \"aports_commit\": \"$(_json_escape "$aports_commit")\","
        echo "  \"codex_tag\": \"$(_json_escape "$manifest_codex_tag")\","
        echo "  \"alpine_mirror\": \"$(_json_escape "$ALPINE_MIRROR")\","
        echo "  \"alpine_repo_snapshot\": \"$(_json_escape "${ALPINE_REPO_SNAPSHOT:-}")\","
        echo "  \"source_commit\": \"$(_json_escape "$source_commit")\","
        echo "  \"build_host\": \"$(_json_escape "$build_host")\","
        echo "  \"build_kernel\": \"$(_json_escape "$build_kernel")\","
        echo "  \"repositories\": ["
        local prefix="" url sum
        for entry in "${REPO_STATE[@]}"; do
            url="${entry%%=*}"
            sum="${entry#*=}"
            echo "    ${prefix}{\"url\": \"$(_json_escape "$url")\", \"apkindex_sha256\": \"$(_json_escape "$sum")\"}"
            prefix=","
        done
        echo "  ]"
        echo "}"
    } > "$manifest_json"
    log_info "Wrote ${manifest_json}"
}

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
    log_step "Build Complete"

    echo ""
    echo "  Output directory: $OUTDIR"
    echo ""
    find "$OUTDIR" -maxdepth 1 -type f \
        \( -name '*.iso' -o -name '*.raw.img' -o -name 'SHA256SUMS' \
           -o -name 'build-manifest.txt' -o -name 'build-manifest.json' \) \
        -exec ls -lh {} \;
    echo ""
    log_info "Reproducibility: compare SHA256SUMS across two builds; pin inputs via"
    log_info "  ALPINE_REPO_SNAPSHOT + CODEX_VERSION + aports branch (see build-manifest.txt)."
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
    capture_repo_state
    generate_checksums
    generate_build_manifest
    print_summary
}

main "$@"
