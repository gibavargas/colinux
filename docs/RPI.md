# CoLinux on Raspberry Pi 4 / 5 (ARM64)

CoLinux Lite ships `aarch64` builds for Raspberry Pi 4 and 5. This page covers
what is supported, how to build/flash, and how to validate on real hardware.

## What you get

| Artifact | Description |
|----------|-------------|
| `colinux-lite-aarch64-*.iso` | Live ISO — **EFI only** (no syslinux/isohybrid on ARM64; GRUB arm64-efi) |
| `colinux-lite-aarch64-*.raw.img` | GPT image: ESP (FAT32) + boot partition (ext4) with GRUB arm64-efi |

The ARM64 image uses Alpine's generic `linux-lts` kernel (mainline, includes
BCM2711/BCM2712 support) with an initramfs that loads `loop`, `squashfs`,
`sd-mod`, `usb-storage`, and `nvme` (RPi 5 NVMe HATs) modules.

## UEFI firmware — required

The aarch64 ISO and raw image boot through GRUB **EFI**. Raspberry Pi 4/5 do
not ship UEFI firmware by default, so you must provide it:

- **RPi 4**: flash the community UEFI firmware
  ([pftf/RPi4_UEFI](https://github.com/pftf/RPi4_UEFI) releases) — either
  write the `RPi4_UEFI_*.zip` contents to a FAT32 SD card and boot from it,
  or install via `rpi-eeprom-update`-style tooling.
- **RPi 5**: use the official UEFI support
  ([RPi5 UEFI](https://github.com/pftf/RPi5_UEFI) releases). Boot the UEFI
  firmware first; it will then find CoLinux on the USB/SD/NVMe media.

> Alternative: keep Raspberry Pi OS's bootloader (config.txt) and chainload —
> but the supported path is UEFI → GRUB.

## Build the aarch64 ISO

From an x86_64 host (cross-build in Docker, as CI does):

```bash
cd ~/CoLinux/colinux
docker run --rm \
  -v "$(pwd):/src" \
  -e ARCH=aarch64 \
  -e ALPINE_RELEASE=3.21 \
  -e OUTDIR=/src/dist \
  alpine:3.21 sh -c \
    'apk add --no-cache alpine-sdk apk-tools alpine-conf bash curl ca-certificates \
       git xorriso squashfs-tools mtools dosfstools grub grub-efi efibootmgr \
       e2fsprogs qemu-img openssl && cd /src && bash scripts/build-alpine.sh'
```

Artifacts land in `dist/` (`colinux-lite-aarch64-3.21-*.iso`, `.raw.img`,
`SHA256SUMS`, `build-manifest.txt/json`). See `docs/BUILD.md` → *Cross
Compilation for ARM64* for details.

## Flash

```bash
# Live ISO → USB stick (whole device, not a partition!)
sudo dd if=dist/colinux-lite-aarch64-3.21-*.iso of=/dev/sdX bs=4M status=progress conv=fsync

# Raw image → SD card or NVMe
sudo dd if=dist/colinux-lite-aarch64-3.21-*.raw.img of=/dev/sdX bs=4M status=progress conv=fsync
```

Then boot the RPi with the UEFI firmware as described above. The raw image
contains a 1 GB boot partition; resize with `parted`/`resize2fs` if you want
more room (the system itself runs diskless from squashfs on tmpfs).

## Smoke test in QEMU (no hardware needed)

```bash
sudo apt install qemu-system-arm qemu-efi-aarch64 expect
./scripts/test-iso.sh --iso dist/colinux-lite-aarch64-3.21-*.iso --arch aarch64 \
  --memory 2048 --timeout 600
```

Requires ARM64 UEFI firmware (`/usr/share/AAVMF/AAVMF_CODE.fd`, provided by
`qemu-efi-aarch64`). CI runs this on every push to `main`.

## Hardware validation checklist (RPi 5, 8 GB)

Manual acceptance test for the v0.6 exit criteria:

1. Boot with UEFI firmware → GRUB menu appears → CoLinux boots to login.
2. `uname -m` prints `aarch64`.
3. `codex --version` prints a version (binary pre-injected in the ISO).
4. `codex-disk-inventory` lists the boot media without errors.
5. `ip link` shows a network interface (ethernet and/or wifi) and
   `codex-network` can connect.
6. Persistence: partition labeled `codex-persist` is detected
   (`blkid -t LABEL=codex-persist`); `codex-usb-persist` works.
7. NVMe (RPi 5 + HAT): boot from NVMe and confirm the root media appears as
   `/dev/nvme0n1`.

Report results back so the ROADMAP exit criterion "ARM64 ISO boots on
Raspberry Pi 5" can be checked off.
