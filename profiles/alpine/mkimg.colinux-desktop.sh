#!/bin/sh
# =============================================================================
# CoLinux Desktop — Alpine mkimage Profile Script
# =============================================================================
# This profile builds a bootable Alpine Linux ISO with GNOME desktop and
# the Electron Codex Desktop app.
#
# Usage (via build-alpine-desktop.sh):
#   sudo ./mkimage.sh --profile colinux-desktop --arch x86_64 \
#       --outdir ./out --repository http://dl-cdn.alpinelinux.org/alpine/v3.21/main
# =============================================================================

profile_colinux_desktop() {
    profile_base

    # ── Identity ──────────────────────────────────────────────────────────────
    title="CoLinux Desktop"
    desc="Alpine Linux with GNOME Desktop and Electron Codex Desktop App"
    profile_name="colinux-desktop"
    image_name="colinux-desktop-$ARCH-$RELEASE"

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
    if [ "$ARCH" = "x86_64" ]; then
        grub_mod="biosdisk part_gpt fat normal configfile linux chain boot"
    else
        grub_mod="part_gpt fat normal configfile linux chain boot"
    fi

    # ── Build stages ──────────────────────────────────────────────────────────
    # Packages come from packages.$ARCH.desktop (handled by mkimage framework)
}

# =============================================================================
# Build phases — called by the mkimage framework in order
# =============================================================================

# Phase: create_image()
profile_colinux_desktop_create_image() {
    local img_size_mb="${COLINUX_IMG_SIZE:-2200}"
    local img_size_sectors=$((img_size_mb * 2048))

    # Create blank image (larger for GNOME + Electron)
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
profile_colinux_desktop_build_kernel() {
    return 0
}

# Phase: install_bootloader()
profile_colinux_desktop_install_bootloader() {
    local mnt="$WORKDIR/esp"
    local boot_mnt="$WORKDIR/boot"

    mkdir -p "$mnt" "$boot_mnt"

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

# Phase: install_extlinux()
profile_colinux_desktop_install_extlinux() {
    return 0
}

# Phase: create_image_ext()
profile_colinux_desktop_create_image_ext() {
    return 0
}

# =============================================================================
# Overlay setup — files in overlay-desktop/ are copied into the rootfs
# =============================================================================
profile_colinux_desktop_overlay() {
    # Ensure overlay directories exist
    mkdir -p "$WORKDIR"/etc
    mkdir -p "$WORKDIR"/etc/gdm
    mkdir -p "$WORKDIR"/etc/NetworkManager
    mkdir -p "$WORKDIR"/etc/dconf/profile
    mkdir -p "$WORKDIR"/etc/dconf/db
    mkdir -p "$WORKDIR"/etc/xdg/autostart
    mkdir -p "$WORKDIR"/etc/polkit-1/localauthority/50-local.d
    mkdir -p "$WORKDIR"/etc/init.d
    mkdir -p "$WORKDIR"/etc/runlevels/boot
    mkdir -p "$WORKDIR"/etc/runlevels/default
    mkdir -p "$WORKDIR"/home/codex/.config
    mkdir -p "$WORKDIR"/home/codex/.local/share/gnome-shell/extensions
    mkdir -p "$WORKDIR"/usr/local/bin
    mkdir -p "$WORKDIR"/usr/local/sbin
    mkdir -p "$WORKDIR"/usr/local/lib/colinux
    mkdir -p "$WORKDIR"/var/log/codex
    mkdir -p "$WORKDIR"/var/lib/colinux
    mkdir -p "$WORKDIR"/run/codex
    mkdir -p "$WORKDIR"/run/seatd
    mkdir -p "$WORKDIR"/opt/codex-desktop/config
    mkdir -p "$WORKDIR"/persist/config/wifi
    mkdir -p "$WORKDIR"/persist/logs
    mkdir -p "$WORKDIR"/workspace

    # Create codex user with consistent uid/gid
    if ! grep -q '^codex:' "$WORKDIR"/etc/passwd 2>/dev/null; then
        echo "codex:x:1000:1000:CoLinux Desktop User:/home/codex:/bin/bash" >> "$WORKDIR"/etc/passwd
        echo "codex:x:1000:" >> "$WORKDIR"/etc/group
        echo "codex:!:$(date +%s):0:99999:7:::" >> "$WORKDIR"/etc/shadow
    fi

    # Add codex to required groups for GNOME desktop
    for grp in video input audio seatd wheel plugdev netdev; do
        if grep -q "^${grp}:" "$WORKDIR"/etc/group 2>/dev/null; then
            if ! grep -q "^${grp}:.*codex" "$WORKDIR"/etc/group 2>/dev/null; then
                sed -i "s/^${grp}:\(.*\)/${grp}:\1,codex/" "$WORKDIR"/etc/group
            fi
        else
            echo "${grp}:x:300:codex" >> "$WORKDIR"/etc/group
        fi
    done

    # Set up autologin for GDM
    mkdir -p "$WORKDIR"/etc/conf.d
    cat > "$WORKDIR"/etc/conf.d/agetty <<'AGETTYCFG'
# Autologin codex user on tty1
agetty_options="--autologin codex --noclear"
AGETTYCFG

    # Create codex-shell.conf with MODE=desktop
    cat > "$WORKDIR"/etc/codex-shell.conf <<'CONF'
# CoLinux Shell Configuration
# Mode: tty | gui | desktop
MODE=desktop

# Desktop environment: gnome
DESKTOP=gnome

# Electron Codex app path
CODEX_ELECTRON=/opt/codex-desktop/codex-desktop

# Whether to fallback to TTY if GNOME fails
DESKTOP_FALLBACK_TTY=true

# Log file for desktop session
DESKTOP_LOG=/persist/logs/desktop-session.log
CONF

    # Copy overlay files from profile directory
    local overlay_dir="${mkimg_profiles_dir:-.}/colinux-desktop/overlay-desktop"
    if [ -d "$overlay_dir" ]; then
        cp -a "$overlay_dir"/* "$WORKDIR"/ 2>/dev/null || true
    fi

    # Compile dconf database
    if [ -f "$WORKDIR"/etc/dconf/db/local-defaults ]; then
        dconf update "$WORKDIR"/etc/dconf/db 2>/dev/null || true
    fi

    # Enable GDM service
    if [ -d "$WORKDIR"/etc/runlevels/default ]; then
        ln -sf /etc/init.d/gdm "$WORKDIR"/etc/runlevels/default/gdm 2>/dev/null || true
    fi

    # Enable NetworkManager service
    if [ -d "$WORKDIR"/etc/runlevels/default ]; then
        ln -sf /etc/init.d/NetworkManager "$WORKDIR"/etc/runlevels/default/NetworkManager 2>/dev/null || true
        ln -sf /etc/init.d/NetworkManager "$WORKDIR"/etc/runlevels/boot/NetworkManager 2>/dev/null || true
    fi

    # Enable codex-network service
    ln -sf /etc/init.d/codex-network "$WORKDIR"/etc/runlevels/boot/codex-network 2>/dev/null || true

    # Enable auto-update service
    ln -sf /etc/init.d/codex-auto-update "$WORKDIR"/etc/runlevels/default/codex-auto-update 2>/dev/null || true

    # Ensure proper permissions
    chown -R root:root "$WORKDIR"
    chmod 755 "$WORKDIR"/home/codex
    chown 1000:1000 "$WORKDIR"/home/codex
    chown -R 1000:1000 "$WORKDIR"/home/codex/.config 2>/dev/null || true
    chown -R 1000:1000 "$WORKDIR"/home/codex/.local 2>/dev/null || true
    chmod 700 "$WORKDIR"/var/lib/colinux
    chmod 2755 "$WORKDIR"/run/seatd 2>/dev/null || true
}
