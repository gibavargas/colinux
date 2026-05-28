# Building CoLinux

This document describes how to build CoLinux editions from source.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Build (colinux-lite)](#quick-build-colinux-lite)
- [Building Other Editions](#building-other-editions)
- [Build Script Reference](#build-script-reference)
- [QEMU Testing & Smoke Tests](#qemu-testing--smoke-tests)
- [Environment Variables](#environment-variables)
- [Cross-Compilation for ARM64](#cross-compilation-for-arm64)
- [Debugging Build Failures](#debugging-build-failures)

---

## Prerequisites

### Option A: Docker (recommended, works on any host)

Docker is the easiest way to build. The Alpine ISO build runs entirely inside an `alpine:3.21` container.

```bash
# No host dependencies beyond Docker itself
docker pull alpine:3.21
```

### Option B: Alpine Linux host

An Alpine Linux 3.21+ system (physical, VM, or LXC) can run the build natively.

```bash
sudo apk add alpine-sdk apk-tools alpine-conf bash curl ca-certificates \
    git xorriso squashfs-tools mtools dosfstools grub grub-efi efibootmgr \
    e2fsprogs qemu-img openssl
```

---

## Quick Build (colinux-lite)

### Using Docker

```bash
git clone https://github.com/gibavargas/colinux.git
cd colinux

docker run --rm \
  -v "$(pwd):/src" \
  -e ARCH=x86_64 \
  -e OUTDIR=/src/dist \
  alpine:3.21 \
  sh -c "apk add --no-cache alpine-sdk apk-tools alpine-conf bash curl \
    ca-certificates git xorriso squashfs-tools mtools dosfstools grub grub-efi \
    efibootmgr e2fsprogs qemu-img openssl && cd /src && bash scripts/build-alpine.sh"
```

Output: `dist/colinux-lite-x86_64-*.iso`

### On Alpine Linux host

```bash
cd colinux
sudo bash scripts/build-alpine.sh --arch x86_64
```

### Validate the ISO with QEMU

```bash
# Run automated smoke tests (boot + codex binary + disk inventory + network)
./scripts/test-iso.sh --iso dist/colinux-lite-x86_64-*.iso

# Or boot interactively for manual testing
./scripts/build-qemu.sh --iso dist/colinux-lite-x86_64-*.iso --boot --no-gui
```

### Write to USB

```bash
lsblk                          # find your USB device
sudo dd if=dist/colinux-lite-x86_64-*.iso of=/dev/sdX bs=4M status=progress && sync
```

---

## Building Other Editions

### colinux-lite-gui (Alpine, Wayland kiosk)

```bash
# Docker build
docker run --rm -v "$(pwd):/src" -e ARCH=x86_64 -e OUTDIR=/src/dist \
  alpine:3.21 sh -c "apk add --no-cache alpine-sdk apk-tools alpine-conf bash curl \
    ca-certificates git xorriso squashfs-tools mtools dosfstools grub grub-efi \
    efibootmgr e2fsprogs qemu-img openssl && cd /src && bash scripts/build-alpine-gui.sh"

# Or native Alpine
sudo bash scripts/build-alpine-gui.sh --arch x86_64
```

### colinux-compat (Debian minimal)

```bash
sudo bash scripts/build-debian-compat.sh --arch amd64
```

See `.github/workflows/build-debian.yml` for CI-based Debian builds, which require
specific live-build workarounds for Ubuntu runners.

### colinux-desktop (Alpine + GNOME + Electron)

```bash
# Docker build
docker run --rm -v "$(pwd):/src" -e ARCH=x86_64 -e OUTDIR=/src/dist \
  alpine:3.21 sh -c "apk add --no-cache alpine-sdk apk-tools alpine-conf bash curl \
    ca-certificates git xorriso squashfs-tools mtools dosfstools grub grub-efi \
    efibootmgr e2fsprogs qemu-img openssl && cd /src && bash scripts/build-alpine-desktop.sh"
```

### Docker environment validation

Each edition has a Dockerfile for quick syntax and dependency validation:

```bash
docker build -t colinux-lite:test .                              # colinux-lite
docker build -t colinux-lite-gui:test -f Dockerfile-gui .        # colinux-lite-gui
docker build -t colinux-compat:test -f Dockerfile-compat .       # colinux-compat
docker build -t colinux-desktop:test -f Dockerfile-desktop .     # colinux-desktop
```

---

## Build Script Reference

| Script | Edition | Notes |
|--------|---------|-------|
| `scripts/build-alpine.sh` | colinux-lite | Alpine mkimage-based ISO |
| `scripts/build-alpine-gui.sh` | colinux-lite-gui | Same base + GUI packages |
| `scripts/build-alpine-desktop.sh` | colinux-desktop | Same base + GNOME + Electron |
| `scripts/build-debian-compat.sh` | colinux-compat | live-build-based Debian ISO |
| `scripts/build-debian.sh` | colinux-desktop (Debian) | live-build Debian Desktop ISO |
| `scripts/test-iso.sh` | All | QEMU smoke tests |
| `scripts/build-qemu.sh` | All | Create QCOW2 + interactive QEMU boot |

### Build script options

```bash
scripts/build-alpine.sh [--arch x86_64|aarch64] [--release 3.21] [--outdir ./dist]
scripts/build-debian-compat.sh [--arch amd64]
```

---

## QEMU Testing & Smoke Tests

### Automated smoke tests

```bash
# Test a specific ISO
./scripts/test-iso.sh --iso dist/colinux-lite-x86_64-v3.21.iso

# Auto-find the latest ISO in dist/
./scripts/test-iso.sh

# Custom timeout and memory
./scripts/test-iso.sh --iso dist/colinux-lite-x86_64-v3.21.iso --timeout 300 --memory 2048
```

The smoke test boots the ISO in QEMU and validates:
1. Boot completes (kernel + init → login prompt)
2. Codex binary exists and is executable
3. `codex-disk-inventory` runs without error
4. Network interface is present
5. Persistence partition detection works

### Interactive QEMU boot

```bash
# Boot with serial console (headless)
./scripts/build-qemu.sh --iso dist/colinux-lite-x86_64-v3.21.iso --boot --no-gui

# Boot with graphical display
./scripts/build-qemu.sh --iso dist/colinux-lite-x86_64-v3.21.iso --boot

# From a raw disk image
./scripts/build-qemu.sh --raw dist/colinux-lite-x86_64.raw.img --boot --no-gui
```

SSH forwarding: `localhost:2222` → guest port 22

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ARCH` | `x86_64` | Target architecture |
| `ALPINE_RELEASE` | `3.21` | Alpine version |
| `ALPINE_MIRROR` | `http://dl-cdn.alpinelinux.org/alpine` | Alpine package mirror |
| `CODEX_VERSION` | `latest` | Codex CLI version to bundle |
| `OUTDIR` | `./dist` | Output directory |

---

## Cross-Compilation for ARM64

```bash
# Build aarch64 ISO in Docker
docker run --rm -v "$(pwd):/src" -e ARCH=aarch64 -e OUTDIR=/src/dist \
  alpine:3.21 sh -c "apk add --no-cache alpine-sdk apk-tools alpine-conf bash curl \
    ca-certificates git xorriso squashfs-tools mtools dosfstools grub grub-efi \
    efibootmgr e2fsprogs qemu-img openssl && cd /src && bash scripts/build-alpine.sh"
```

Note: aarch64 ISO does not include syslinux/isohybrid (x86-only). Boot via EFI.

---

## Debugging Build Failures

### Alpine build: "Images generated" but empty output

The `arch` variable in the Alpine mkimage profile must be set. If missing, the profile is silently skipped. Verify `profiles/alpine/` contains `arch="x86_64 aarch64"`.

### Alpine build: `update-kernel` errors

Non-fatal `depmod` and BusyBox `install` warnings during kernel extraction are expected. The build script patches these to `|| true`.

### Docker build fails on a specific Dockerfile

Common causes:
- Wrong package names for the distro (Alpine uses `apk`, Debian uses `apt`)
- Stale `COPY` paths referencing files that were moved or renamed
- Dockerfile backslash continuation doubled by patch tools

### Syntax check all shell scripts

```bash
find . -name "*.sh" -not -path "*/.git/*" | xargs -I{} bash -n {} 2>&1
```

### CI build logs

```bash
gh run list --repo gibavargas/colinux --limit 5
gh run view <run-id> --log-failed
```
