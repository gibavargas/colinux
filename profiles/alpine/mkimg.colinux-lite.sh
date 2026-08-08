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
    # Override profile_base's initfs_cmdline to remove 'quiet' — under QEMU TCG
    # software emulation (CI), 'quiet' suppresses all boot output, making it
    # impossible to tell if the kernel is loading.
    #
    # Console ordering: Linux makes the LAST console= on the command line the
    # primary /dev/console. Putting ttyS0 last ensures that in headless / QEMU
    # -nographic mode, OpenRC output and the login prompt appear on serial.
    # (tty0 first = console output also goes to the virtual VGA, harmless.)
    initfs_cmdline="modules=loop,squashfs,sd-mod,usb-storage console=tty0 console=ttyS0,115200"
    kernel_cmdline="modules=loop,squashfs,sd-mod,usb-storage overlaytmpfs init=/sbin/init console=tty0 console=ttyS0,115200"

    # modloop signing is DISABLED: profile_base sets modloop_sign=yes, which
    # makes mkimg.base.sh pass --modloopsign to update-kernel. update-kernel
    # then runs sign_modloop(), which fails (openssl: empty PACKAGER_PRIVKEY)
    # and aborts BEFORE vmlinuz/initramfs are copied into /boot — producing a
    # kernel-less ISO (issue #2). The signature is only needed to verify the
    # modloop against a trusted key at boot; without keys it must be skipped.
    modloop_sign=""

    # ── Architecture-specific settings ────────────────────────────────────────
    # NOTE: mkimg.base.sh iterates $kernel_flavors (plural, set by profile_base);
    # kernel_flavor (singular) is a dead variable — kept in sync for clarity.
    case "$ARCH" in
        x86_64)
            kernel_flavors="lts"
            kernel_addons=""
            ;;
        aarch64)
            kernel_flavors="lts"
            kernel_addons=""
            ;;
    esac

    # ── Overlay (apkovl) ──────────────────────────────────────────────────────
    # profile_base sets apkovl="" (empty) and hostname="alpine". Without an
    # apkovl script, section_apkovl() in mkimg.base.sh silently returns and the
    # overlay directory (inittab with serial getty, doas.conf, codex-* wrappers,
    # OpenRC services) is NEVER packaged into the ISO. The booted system is a
    # stock Alpine with no serial getty, no enabled services, and no codex
    # binaries — QEMU smoke test sees a kernel boot then silence (issue #2).
    #
    # genapkovl-colinux.sh is a generator script that copies the overlay tree
    # and creates OpenRC runlevel symlinks into <hostname>.apkovl.tar.gz, which
    # mkimage bakes into the ISO root filesystem.
    apkovl="genapkovl-colinux.sh"
    hostname="colinux"

    # ── Boot loader configuration ─────────────────────────────────────────────
    # GRUB modules for EFI boot (used by section_grub_efi in mkimg.base.sh)
    # Note: biosdisk is i386-pc only — do NOT include for EFI grub-mkimage
    grub_mod="part_gpt fat normal configfile linux chain boot"

    # ── Image layout ──────────────────────────────────────────────────────────
    # Partition 1: EFI System Partition (ESP) — FAT32, ~32 MB
    # Partition 2: Boot partition with kernel + initramfs + squashfs
    #
    # For diskless mode the entire root filesystem lives in a squashfs image
    # on the ISO, extracted to tmpfs at boot.  Persistent data lives on an
    # optional "codex-persist" partition on the target USB/disk.
}
