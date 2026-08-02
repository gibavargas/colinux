#!/bin/sh
# =============================================================================
# CoLinux Lite GUI — Alpine mkimage Profile Script
# =============================================================================
# This profile builds a bootable, diskless Alpine Linux ISO optimized for
# running OpenAI Codex CLI as the primary interface in a Wayland kiosk.
#
# The GUI edition uses cage (Wayland kiosk compositor) to run foot (terminal
# emulator) fullscreen, which in turn launches Codex CLI.  Falls back to TTY
# if Wayland/GPU is unavailable.
#
# IMPORTANT — mkimage.sh framework rules (v3.21.0):
#   * The profile function MUST be named `profile_$PROFILE` exactly as passed
#     with --profile.  Since we build with `--profile colinux-lite-gui`, the
#     function must be `profile_colinux-lite-gui()` (hyphens, not underscores).
#     A mismatched name makes `profile_$PROFILE` fail and the build aborts
#     under `set -e`.
#   * `arch` MUST list the supported architectures; without it mkimage.sh's
#     `list_has $ARCH $arch` silently skips the profile (build "succeeds"
#     with an empty outdir).
#   * `image_ext` + `output_format` are required for ISO output.
#   * mkimage.sh calls `profile_$PROFILE` then every `section_*` function.
#     Functions named `profile_*_phase` are NEVER called — custom content
#     must be wired through a `section_*`/`build_*` pair (see
#     section_colinux_gui_overlay below).
#   * `kernel_addons` must be empty on Alpine 3.21: `intel-agp-lts`,
#     `i915-lts` and `drm-lts` are not packages in the 3.21 repos and make
#     section_kernels fail.
#   * `biosdisk` is i386-pc only — it must NOT appear in `grub_mod` for
#     EFI builds or grub-mkimage fails on x86_64-efi.
# =============================================================================

profile_colinux-lite-gui() {
    profile_base

    # ── Identity ──────────────────────────────────────────────────────────────
    title="CoLinux Lite GUI"
    desc="Bootable Alpine Linux appliance for OpenAI Codex CLI (Wayland kiosk)"
    profile_name="colinux-lite-gui"
    image_name="colinux-lite-gui-$ARCH-$RELEASE"
    image_ext="iso"
    output_format="iso"
    arch="x86_64 aarch64"

    # ── Kernel & Initramfs ────────────────────────────────────────────────────
    # i915/drm/efi_pstore module loading is x86_64-only; aarch64 panels use
    # the base module set from profile_base (via kernel_cmdline override).
    case "$ARCH" in
        x86_64)
            kernel_cmdline="quiet modules=loop,squashfs,sd-mod,usb-storage,i915,drm,efi_pstore overlaytmpfs init=/sbin/init"
            ;;
        aarch64)
            kernel_cmdline="quiet modules=loop,squashfs,sd-mod,usb-storage overlaytmpfs init=/sbin/init"
            ;;
    esac
    kernel_cmdline="$(echo "$kernel_cmdline" | tr -s '[:space:]' ' ' | sed 's/^ //')"

    # ── Architecture-specific settings ────────────────────────────────────────
    case "$ARCH" in
        x86_64)
            kernel_flavors="lts"
            kernel_addons=""
            ;;
        aarch64)
            kernel_flavors="lts"
            kernel_addons=""
            ;;
        *)
            echo "ERROR: Unsupported architecture: $ARCH" >&2
            return 1
            ;;
    esac

    # ── Boot loader configuration ─────────────────────────────────────────────
    # GRUB modules for EFI boot (used by section_grub_efi in mkimg.base.sh).
    # Note: biosdisk is i386-pc only — do NOT include for EFI grub-mkimage.
    grub_mod="part_gpt fat normal configfile linux chain boot"

    # ── Image layout ──────────────────────────────────────────────────────────
    # Partition 1: EFI System Partition (ESP) — FAT32, ~32 MB
    # Partition 2: Boot partition with kernel + initramfs + squashfs
    #
    # For diskless mode the entire root filesystem lives in a squashfs image
    # on the ISO, extracted to tmpfs at boot.  Persistent data lives on an
    # optional "codex-persist" partition on the target USB/disk.
}

# =============================================================================
# Overlay + appliance setup — wired through the section_* framework hook
# =============================================================================
# mkimage.sh calls every `section_*` function defined in any loaded
# mkimg.*.sh, so a custom section is the supported way to inject our
# overlay into the image.  build_section creates a per-section DESTDIR
# ($WORKDIR/<section>.work) that is later merged into the final rootfs.
#
# This section performs what used to live in (never-called) profile_*_phase
# functions: it creates the codex user + groups, autologin on tty1,
# /etc/codex-shell.conf, and copies profiles/alpine/overlay-gui/ into the
# image root.

build_colinux_gui_overlay() {
    # The overlay is staged next to this profile by build-alpine-gui.sh at
    # $APORTS_DIR/scripts/colinux-lite-gui/overlay-gui.  $scriptdir is set by
    # mkimage.sh to the directory containing mkimage.sh (aports/scripts).
    local overlay_dir="${scriptdir:-.}/colinux-lite-gui/overlay-gui"
    [ -d "$overlay_dir" ] || return 0

    # ── Base directories ─────────────────────────────────────────────────────
    mkdir -p "$DESTDIR/etc/cage" "$DESTDIR/etc/fonts" "$DESTDIR/etc/foot" \
        "$DESTDIR/etc/sway" "$DESTDIR/etc/udev/rules.d" \
        "$DESTDIR/etc/xdg/foot" "$DESTDIR/etc/init.d" \
        "$DESTDIR/home/codex" "$DESTDIR/usr/local/bin" \
        "$DESTDIR/usr/local/sbin" "$DESTDIR/usr/local/lib/colinux" \
        "$DESTDIR/var/log/codex" "$DESTDIR/var/lib/colinux" \
        "$DESTDIR/run/codex" "$DESTDIR/run/seatd" \
        "$DESTDIR/persist/config/wifi" "$DESTDIR/persist/logs"

    # ── Create codex user with consistent uid/gid ────────────────────────────
    if ! grep -q '^codex:' "$DESTDIR/etc/passwd" 2>/dev/null; then
        echo "codex:x:1000:1000:CoLinux GUI User:/home/codex:/bin/bash" >> "$DESTDIR/etc/passwd"
        echo "codex:x:1000:" >> "$DESTDIR/etc/group"
        echo "codex:!:$(date +%s):0:99999:7:::" >> "$DESTDIR/etc/shadow"
    fi

    # Add codex to seatd group for Wayland access
    if ! grep -q '^seatd:' "$DESTDIR/etc/group" 2>/dev/null; then
        echo "seatd:x:200:codex" >> "$DESTDIR/etc/group"
    elif ! grep -q '^seatd:.*codex' "$DESTDIR/etc/group" 2>/dev/null; then
        sed -i 's/^seatd:\(.*\)/seatd:\1,codex/' "$DESTDIR/etc/group"
    fi

    # Add codex to video/input/audio groups for GPU + input access (touch)
    for grp in video input audio; do
        if grep -q "^${grp}:" "$DESTDIR/etc/group" 2>/dev/null; then
            if ! grep -q "^${grp}:.*codex" "$DESTDIR/etc/group" 2>/dev/null; then
                sed -i "s/^${grp}:\(.*\)/${grp}:\1,codex/" "$DESTDIR/etc/group"
            fi
        else
            echo "${grp}:x:300:codex" >> "$DESTDIR/etc/group"
        fi
    done

    # ── Autologin for tty1 (getty) — GUI shell takes over ────────────────────
    mkdir -p "$DESTDIR/etc/conf.d"
    cat > "$DESTDIR/etc/conf.d/agetty" <<'AGETTYCFG'
# Autologin codex user on tty1
agetty_options="--autologin codex --noclear"
AGETTYCFG

    # ── Copy overlay files (etc/, home/, usr/local/...) into the image ───────
    cp -a "$overlay_dir"/. "$DESTDIR"/ 2>/dev/null || true

    # ── Ensure proper permissions ────────────────────────────────────────────
    chmod 755 "$DESTDIR/home/codex"
    chown 1000:1000 "$DESTDIR/home/codex" 2>/dev/null || true
    chmod 700 "$DESTDIR/var/lib/colinux" 2>/dev/null || true
    chmod 2755 "$DESTDIR/run/seatd" 2>/dev/null || true
    # doas.conf must be root-readable only (cp -a preserves umask-inflated modes)
    if [ -f "$DESTDIR/etc/doas.conf" ]; then
        chown root:root "$DESTDIR/etc/doas.conf" 2>/dev/null || true
        chmod 640 "$DESTDIR/etc/doas.conf"
    fi
    find "$DESTDIR/etc/sudoers.d" -type f -exec chmod 440 {} \; 2>/dev/null || true
}

section_colinux_gui_overlay() {
    build_section colinux_gui_overlay overlay-gui
}
