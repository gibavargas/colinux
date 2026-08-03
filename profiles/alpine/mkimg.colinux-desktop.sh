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
#
# CRITICAL mkimage.sh requirements (all three were missing in v0.5):
#   1. Function name MUST match --profile arg exactly: profile_colinux-desktop
#      (hyphenated — ash allows this even though POSIX sh -n reports it)
#   2. arch="x86_64 aarch64" MUST be set or the profile is silently skipped
#   3. image_ext="iso" + output_format="iso" MUST be set or no ISO is produced
#   4. profile_*_phase functions are DEAD CODE — mkimage never calls them.
#      All build work is done by section_* functions in mkimg.base.sh.
# =============================================================================

profile_colinux-desktop() {
    profile_base

    # ── Identity ──────────────────────────────────────────────────────────────
    title="CoLinux Desktop"
    desc="Alpine Linux with GNOME Desktop and Electron Codex Desktop App"
    profile_name="colinux-desktop"
    image_name="colinux-desktop-$ARCH-$RELEASE"

    # ── MANDATORY variables for ISO output ────────────────────────────────────
    # Without all three of these, mkimage exits 0 but produces an empty output
    # directory — the #1 silent failure documented in audit findings.
    arch="x86_64 aarch64"
    image_ext="iso"
    output_format="iso"

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
            # NOTE: Alpine 3.21 removed intel-agp-lts, drm-lts, i915-lts as
            # separate packages. The functionality is built into linux-lts
            # itself. Setting kernel_addons to these causes build_kernel to
            # fail with "package not found" (audit finding: Alpine 3.21 pitfall).
            kernel_addons=""
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
    # GRUB modules for EFI boot (used by section_grub_efi in mkimg.base.sh)
    # biosdisk is i386-pc only — do NOT include it for x86_64-efi or aarch64
    # (audit finding: including biosdisk causes grub-mkimage to fail on EFI).
    grub_mod="part_gpt fat normal configfile linux chain boot memdisk tar"

    # ── Packages ──────────────────────────────────────────────────────────────
    # Packages come from packages.$ARCH.desktop (handled by mkimage framework
    # via the auto-discovered packages.colinux-desktop.$ARCH file)
}
