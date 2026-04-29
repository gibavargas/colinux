#!/bin/sh
# =============================================================================
# CodexOS Lite GUI — Alpine mkimage Profile Script
# =============================================================================
# This profile builds a bootable, diskless Alpine Linux ISO optimized for
# running OpenAI Codex CLI as the primary interface in a Wayland kiosk.
#
# The GUI edition uses cage (Wayland kiosk compositor) to run foot (terminal
# emulator) fullscreen, which in turn launches Codex CLI.  Falls back to TTY
# if Wayland/GPU is unavailable.
#
# Usage (via build-alpine-gui.sh):
#   sudo ./mkimage.sh --profile codexos-lite-gui --arch x86_64 \
#       --outdir ./out --repository http://dl-cdn.alpinelinux.org/alpine/v3.21/main
# =============================================================================

profile_codexos_lite_gui() {
    profile_base

    # ── Identity ──────────────────────────────────────────────────────────────
    title="CodexOS Lite GUI"
    desc="Bootable Alpine Linux appliance for OpenAI Codex CLI (Wayland kiosk)"
    profile_name="codexos-lite-gui"
    image_name="codexos-lite-gui-$ARCH-$RELEASE"

    # ── Kernel & Initramfs ────────────────────────────────────────────────────
    kernel_cmdline="
        quiet
        modules=loop,squashfs,sd-mod,usb-storage,i915,drm,efi_pstore
        overlaytmpfs
        init=/sbin/init
    "

    # Remove leading whitespace from cmdline
    kernel_cmdline="$(echo "$kernel_cmdline" | tr -s '[:space:]' ' ' | sed 's/^ //')"

    # ── Architecture-specific settings ────────────────────────────────────────
    case "$ARCH" in
        x86_64)
            kernel_flavor="lts"
            kernel_addons="intel-agp i915 drm"
            bootloader="grub"
            ;;
        aarch64)
            kernel_flavor="lts"
            kernel_addons=""
            bootloader="grub"
            ;;
        *)
            echo "ERROR: Unsupported architecture: $ARCH" >&2
            return 1
            ;;
    esac

    # ── Boot loader configuration ─────────────────────────────────────────────
    # We build an EFI-capable ISO with GRUB
    if [ "$ARCH" = "x86_64" ]; then
        grub_mod="biosdisk part_gpt fat normal configfile linux chain boot"
    else
        grub_mod="part_gpt fat normal configfile linux chain boot"
    fi

    # ── Image layout ──────────────────────────────────────────────────────────
    # Partition 1: EFI System Partition (ESP) — FAT32, ~32 MB
    # Partition 2: Boot partition with kernel + initramfs + squashfs
    #
    # For diskless mode the entire root filesystem lives in a squashfs image
    # on the ISO, extracted to tmpfs at boot.  Persistent data lives on an
    # optional "codex-persist" partition on the target USB/disk.

    # Packages come from packages.$ARCH.gui (handled by mkimage framework)
    # apkbuild_flags="--no-scripts"  # keep scripts for service setup

    # ── Build stages ──────────────────────────────────────────────────────────
    # The mkimage framework calls these hooks in order.

    # Trace: mkimg.codexos-lite-gui.sh loaded for $ARCH
}

# =============================================================================
# Build phases — called by the mkimage framework in order
# =============================================================================

# Phase: create_image()
#   Sets up the disk image with partition table.
profile_codexos_lite_gui_create_image() {
    local img_size_mb="${CODEXOS_IMG_SIZE:-900}"
    local img_size_sectors=$((img_size_mb * 2048))

    # Create blank image (slightly larger for GUI packages)
    truncate -s "${img_size_mb}M" "$IMG"

    # Write a protective MBR + GPT
    sfdisk "$IMG" <<EOF
label: gpt
unit: sectors

start=2048,  size=65536, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="codex-efi"
start=67584, size=*,    type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="codex-boot"
EOF
}

# Phase: build_kernel()
#   Installs the kernel and generates initramfs.
profile_codexos_lite_gui_build_kernel() {
    # Called automatically by mkimage — packages list drives kernel install
    return 0
}

# Phase: install_bootloader()
#   Installs GRUB EFI onto the ESP.
profile_codexos_lite_gui_install_bootloader() {
    local mnt="$WORKDIR/esp"
    local boot_mnt="$WORKDIR/boot"

    mkdir -p "$mnt" "$boot_mnt"

    # Mount ESP
    local esp_offset=$((2048 * 512))
    local esp_size=$((65536 * 512))
    setup_loop "$IMG" "$esp_offset" "$esp_size" 2>/dev/null
    local esp_dev="${LOOPDEV}"

    mount -t vfat "$esp_dev" "$mnt" 2>/dev/null || {
        mkfs.vfat -F 32 -n "CODEX-EFI" "$esp_dev"
        mount -t vfat "$esp_dev" "$mnt"
    }

    mkdir -p "$mnt/EFI/BOOT"
    mkdir -p "$mnt/EFI/CODEX"

    case "$ARCH" in
        x86_64)
            cp "$ROOTDIR/usr/lib/grub/i386-efi/grubx64.efi" "$mnt/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || true
            ;;
        aarch64)
            cp "$ROOTDIR/usr/lib/grub/arm64-efi/grub.efi" "$mnt/EFI/BOOT/BOOTAA64.EFI" 2>/dev/null || true
            ;;
    esac

    umount "$mnt"
    unset_loop "$esp_dev" 2>/dev/null || true
}

# Phase: install_extlinux()  (fallback for BIOS boot on x86_64)
profile_codexos_lite_gui_install_extlinux() {
    # Only needed for legacy BIOS; EFI is primary
    return 0
}

# Phase: create_image_ext()
#   Finalizes the ISO / raw image with squashfs root.
profile_codexos_lite_gui_create_image_ext() {
    # The mkimage framework handles ISO creation for us.
    # We add extra files via overlay.
    return 0
}

# =============================================================================
# Overlay setup — files in overlay-gui/ are copied into the rootfs
# =============================================================================
profile_codexos_lite_gui_overlay() {
    # Ensure overlay directories exist
    mkdir -p "$WORKDIR"/etc
    mkdir -p "$WORKDIR"/etc/sway
    mkdir -p "$WORKDIR"/etc/cage
    mkdir -p "$WORKDIR"/etc/udev/rules.d
    mkdir -p "$WORKDIR"/etc/dbus-1
    mkdir -p "$WORKDIR"/home/codex
    mkdir -p "$WORKDIR"/usr/local/bin
    mkdir -p "$WORKDIR"/usr/local/sbin
    mkdir -p "$WORKDIR"/usr/local/lib/codexos
    mkdir -p "$WORKDIR"/var/log/codex
    mkdir -p "$WORKDIR"/var/lib/codexos
    mkdir -p "$WORKDIR"/run/codex
    mkdir -p "$WORKDIR"/run/seatd
    mkdir -p "$WORKDIR"/persist/config/wifi
    mkdir -p "$WORKDIR"/persist/logs

    # Create codex user with consistent uid/gid
    if ! grep -q '^codex:' "$WORKDIR"/etc/passwd 2>/dev/null; then
        echo "codex:x:1000:1000:CodexOS GUI User:/home/codex:/bin/bash" >> "$WORKDIR"/etc/passwd
        echo "codex:x:1000:" >> "$WORKDIR"/etc/group
        echo "codex:!:$(date +%s):0:99999:7:::" >> "$WORKDIR"/etc/shadow
    fi

    # Add codex to seatd group for Wayland access
    if ! grep -q '^seatd:' "$WORKDIR"/etc/group 2>/dev/null; then
        echo "seatd:x:200:codex" >> "$WORKDIR"/etc/group
    elif ! grep -q '^seatd:.*codex' "$WORKDIR"/etc/group 2>/dev/null; then
        sed -i 's/^seatd:\(.*\)/seatd:\1,codex/' "$WORKDIR"/etc/group
    fi

    # Add codex to video and input groups for GPU/input access
    for grp in video input audio; do
        if grep -q "^${grp}:" "$WORKDIR"/etc/group 2>/dev/null; then
            if ! grep -q "^${grp}:.*codex" "$WORKDIR"/etc/group 2>/dev/null; then
                sed -i "s/^${grp}:\(.*\)/${grp}:\1,codex/" "$WORKDIR"/etc/group
            fi
        else
            echo "${grp}:x:300:codex" >> "$WORKDIR"/etc/group
        fi
    done

    # Set up autologin for tty1 (getty) — GUI shell takes over
    mkdir -p "$WORKDIR"/etc/conf.d
    cat > "$WORKDIR"/etc/conf.d/agetty <<'AGETTYCFG'
# Autologin codex user on tty1
agetty_options="--autologin codex --noclear"
AGETTYCFG

    # Create codex-shell.conf with MODE=gui
    cat > "$WORKDIR"/etc/codex-shell.conf <<'CONF'
# CodexOS Shell Configuration
# Mode: tty | gui
MODE=gui

# GUI compositor: cage | sway
COMPOSITOR=cage

# GUI terminal emulator
GUI_TERMINAL=foot

# Whether to fallback to TTY if Wayland fails
GUI_FALLBACK_TTY=true

# Log file for GUI session
GUI_LOG=/persist/logs/gui-session.log
CONF

    # Copy overlay files from profile directory
    local overlay_dir="${mkimg_profiles_dir:-.}/codexos-lite-gui/overlay-gui"
    if [ -d "$overlay_dir" ]; then
        cp -a "$overlay_dir"/* "$WORKDIR"/ 2>/dev/null || true
    fi

    # Ensure proper permissions
    chown -R root:root "$WORKDIR"
    chmod 755 "$WORKDIR"/home/codex
    chown 1000:1000 "$WORKDIR"/home/codex
    chmod 700 "$WORKDIR"/var/lib/codexos
    chmod 2755 "$WORKDIR"/run/seatd 2>/dev/null || true
}
