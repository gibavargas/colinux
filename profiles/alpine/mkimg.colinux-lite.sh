#!/bin/sh
# =============================================================================
# CoLinux Lite — Alpine mkimage Profile Script
# =============================================================================
# This profile builds a bootable, diskless Alpine Linux ISO optimized for
# running OpenAI Codex CLI as the primary interface.
#
# Usage (via build-alpine.sh):
#   sudo ./mkimage.sh --profile colinux-lite --arch x86_64 \
#       --outdir ./out --repository http://dl-cdn.alpinelinux.org/alpine/v3.21/main
#
# NOTE: The mkimage framework uses section_* functions (defined in mkimg.base.sh)
# for actual build phases. This profile only sets variables that those sections
# consume. Functions named profile_*_phase are NOT called by mkimage.sh.
# =============================================================================

profile_colinux-lite() {
    profile_base

    # ── Identity ──────────────────────────────────────────────────────────────
    title="CoLinux Lite"
    desc="Bootable Alpine Linux appliance for OpenAI Codex CLI"
    profile_name="colinux-lite"
    image_name="colinux-lite-$ARCH-$RELEASE"
    image_ext="iso"
    output_format="iso"
    arch="x86_64 aarch64"

    # ── Kernel & Initramfs ────────────────────────────────────────────────────
    kernel_cmdline="quiet modules=loop,squashfs,sd-mod,usb-storage overlaytmpfs init=/sbin/init"

    # ── Architecture-specific settings ────────────────────────────────────────
    case "$ARCH" in
        x86_64)
            kernel_flavor="lts"
            kernel_addons=""
            ;;
        aarch64)
            kernel_flavor="lts"
            kernel_addons=""
            ;;
    esac

    # ── Boot loader configuration ─────────────────────────────────────────────
    # GRUB modules for EFI boot (used by section_grub_efi in mkimg.base.sh)
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
}
