# Building CodexOS Lite

This document describes how to build CodexOS Lite from source.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Build](#quick-build)
- [Step-by-Step Build Instructions](#step-by-step-build-instructions)
- [Build Configuration](#build-configuration)
- [Cross-Compilation for ARM64](#cross-compilation-for-arm64)
- [QEMU Testing](#qemu-testing)
- [Debugging Build Failures](#debugging-build-failures)
- [Custom Package Selection](#custom-package-selection)

---

## Prerequisites

### Option A: Alpine Linux Build Host (Recommended)

An Alpine Linux 3.19+ system (physical, VM, or container) provides the most compatible build environment.

```bash
# Install build dependencies
sudo apk add \
    alpine-sdk \
    apk-tools \
    mkinitfs \
    syslinux \
    xorriso \
    squashfs-tools \
    cryptsetup \
    e2fsprogs \
    dosfstools \
    mtools \
    sfdisk \
    qemu-system-x86_64  # optional, for testing
```

### Option B: Docker

If you don't have Alpine available, use Docker:

```bash
# Pull the Alpine build image
docker pull alpine:3.19

# Run the build in a container
docker run --rm -it \
    --privileged \
    -v $(pwd):/workspace \
    alpine:3.19 \
    sh -c "cd /workspace && apk add alpine-sdk apk-tools mkinitfs syslinux xorriso squashfs-tools cryptsetup && ./build.sh"
```

> Note: `--privileged` is required for `mkinitfs` and `losetup` operations inside the container.

### Option C: Other Linux Distributions

Builds may work on other distributions but are not officially supported. You will need equivalents for:
- `apk-tools` (Alpine package manager)
- `mkinitfs` (Alpine initramfs generator)
- `xorriso` (ISO creation)
- `squashfs-tools` (squashfs creation)

---

## Quick Build

```bash
git clone https://github.com/colinux/codexos.git
cd codexos
sudo ./build.sh
```

Output: `dist/codexos-lite.iso` (~120 MB)

---

## Step-by-Step Build Instructions

### 1. Clone the repository

```bash
git clone https://github.com/colinux/codexos.git
cd codexos
```

### 2. Review the configuration

```bash
cat profiles/alpine/packages.list   # packages to install
cat build.sh                         # main build script
```

### 3. (Optional) Create a build config

```bash
cp build.conf.example build.conf
# Edit build.conf to customize
```

### 4. Run the build

```bash
sudo ./build.sh
```

### 5. The build process

The `build.sh` script performs the following steps:

```
1. Load configuration (build.conf or defaults)
2. Set up build directory (.build/)
3. Install Alpine packages to a temporary root
4. Apply overlay files (init scripts, configs, custom scripts)
5. Generate initramfs with mkinitfs
6. Build the squashfs root filesystem
7. Create the ISO with xorriso and syslinux
8. Generate SHA-256 checksum
9. Copy output to dist/
10. Clean up temporary files
```

Build log: `.build/build.log`

### 6. Verify the output

```bash
ls -lh dist/
# codexos-lite.iso     120M
# codexos-lite.iso.sha256  65B

# Verify checksum
sha256sum -c dist/codexos-lite.iso.sha256
```

---

## Build Configuration

Create a `build.conf` file in the project root to override defaults:

```bash
# build.conf — CodexOS Lite build configuration

# Edition to build
EDITION="codexos-lite"
# Options: codexos-lite, codexos-lite-gui, codexos-compat

# Output directory
OUTPUT_DIR="dist"

# Compression algorithm for squashfs
# Options: xz (default, best), gzip (fast), lzo (fastest), zstd (balanced)
COMPRESSION="xz"

# Enable encrypted persistence support
ENABLE_PERSISTENCE="true"

# Codex CLI version to bundle
# Options: latest, stable, or a specific version tag
CODEX_VERSION="latest"

# Extra Alpine packages beyond the default list
# Space-separated
EXTRA_PACKAGES=""

# Packages to exclude from the default list
# Space-separated
EXCLUDE_PACKAGES=""

# Kernel version (Alpine kernel package)
KERNEL_VERSION="lts"

# ISO volume label
VOLUME_ID="CODEXOS"

# Build verbosity
# Options: quiet, normal, verbose
VERBOSE="normal"
```

### Command-line overrides

```bash
# Override specific options from the command line
sudo ./build.sh --edition codexos-lite-gui --verbose
sudo ./build.sh --compression gzip --output my-output/
sudo ./build.sh --kernel-lts --extra-packages "vim tmux htop"
```

---

## Cross-Compilation for ARM64

CodexOS Lite can be built for ARM64 (aarch64) devices such as Raspberry Pi 4/5 and other single-board computers.

### Prerequisites

```bash
# On x86_64 build host, install cross-compilation tools
sudo apk add gcc-aarch64 musl-aarch64 binutils-aarch64

# Or install the cross-compile toolchain
sudo apk add aarch64-none-elf-gcc
```

### Build for ARM64

```bash
sudo ./build.sh --arch aarch64 --edition codexos-lite
```

### ARM64-specific configuration

```bash
# build.conf
ARCH="aarch64"
KERNEL_VERSION="lts"
KERNEL_FLAVOR="lts"          # or "rpi" for Raspberry Pi
EXTRA_PACKAGES="u-boot-rpiarm64"  # for Raspberry Pi
```

### Flashing ARM64 images

ARM64 builds produce a raw disk image (not an ISO):

```bash
# For Raspberry Pi
sudo dd if=dist/codexos-lite-aarch64.raw of=/dev/sdX bs=4M status=progress && sync
```

### Current ARM64 status

| Platform | Boot method | Status |
|---|---|---|
| Raspberry Pi 4/5 | u-boot + EFI | 🧪 Experimental |
| Generic aarch64 (UEFI) | GRUB EFI | 📋 Planned |
| Rockchip (RK3588) | u-boot | 📋 Planned |

---

## QEMU Testing

Test your build without writing to physical media:

```bash
# Basic test (TTY edition)
./scripts/qemu-test.sh dist/codexos-lite.iso

# With more RAM
./scripts/qemu-test.sh dist/codexos-lite.iso --ram 4096

# With a test disk attached (for disk safety testing)
./scripts/qemu-test.sh dist/codexos-lite.iso --disk test-disk.qcow2

# With network access
./scripts/qemu-test.sh dist/codexos-lite.iso --network

# Serial console (for headless testing)
./scripts/qemu-test.sh dist/codexos-lite.iso --serial
```

### QEMU script details

The `qemu-test.sh` script wraps `qemu-system-x86_64` with sensible defaults:

```bash
#!/bin/sh
# Default QEMU options:
# -m 2048                    # 2 GB RAM
# -smp 2                     # 2 CPU cores
# -cdrom "$ISO"              # Boot from ISO
# -boot d                    # Boot from CD-ROM
# -netdev user,id=net0       # User-mode networking
# -device virtio-net-pci     # Virtio network adapter
# -display none              # No graphical output (use serial)
# -serial stdio              # Serial console on stdio
```

### Creating a test disk image

```bash
# Create a 1 GB test disk
qemu-img create -f qcow2 test-disk.qcow2 1G

# Partition and format it (inside QEMU or with guestfish)
guestfish -a test-disk.qcow2 <<EOF
run
part-disk /dev/sda mbr
mkfs ext4 /dev/sda1
EOF
```

---

## Debugging Build Failures

### Common issues

#### "mkinitfs: unable to find kernel"

```bash
# Verify the kernel is installed
apk info -e linux-lts

# Check kernel modules directory
ls /lib/modules/

# Reinstall kernel
sudo apk add linux-lts linux-lts-dev
```

#### "xorriso: failure: cannot write"

```bash
# Check available disk space
df -h .

# Clean previous build
rm -rf .build/ dist/
```

#### "Permission denied" during build

```bash
# The build must run as root (for mkinitfs, losetup, mount)
sudo ./build.sh

# Or add yourself to the appropriate groups (not recommended)
```

#### "squashfs: compressor not available"

```bash
# Install compression support
sudo apk add xz zstd lzo

# Or switch to gzip (always available)
COMPRESSION="gzip" sudo ./build.sh
```

### Verbose build

```bash
# Run with verbose logging
sudo ./build.sh --verbose

# Or set environment variable
VERBOSE=1 sudo ./build.sh
```

### Build log

The full build log is saved at `.build/build.log`:

```bash
# Tail the log during build
sudo ./build.sh && tail -f .build/build.log

# Search for errors
grep -i error .build/build.log
grep -i fatal .build/build.log
```

### Interactive debug shell

```bash
# The build script supports dropping into a shell at key stages
sudo ./build.sh --debug-shell-after rootfs
# You'll get a shell inside the built rootfs for inspection
```

---

## Custom Package Selection

### Default package list

The default packages are defined in `profiles/alpine/packages.list`:

```
# Core system
alpine-base
linux-lts
linux-firmware-none

# Disk tools
lsblk
parted
fdisk
e2fsprogs
dosfstools
ntfs-3g
cryptsetup
mdadm
lvm2
testdisk

# Networking
dhcpcd
iwd
openssh
curl
wget

# Utilities
jq
less
htop
vim

# Codex runtime
nodejs
npm
```

### Adding packages

**Method 1: Edit packages.list**

```bash
echo "git" >> profiles/alpine/packages.list
echo "tmux" >> profiles/alpine/packages.list
```

**Method 2: build.conf**

```bash
EXTRA_PACKAGES="git tmux strace tcpdump"
```

**Method 3: Command line**

```bash
sudo ./build.sh --extra-packages "git tmux strace"
```

### Removing packages

```bash
# In build.conf
EXCLUDE_PACKAGES="htop vim"
```

### Package notes

| Package | Notes |
|---|---|
| `linux-firmware-none` | Minimal firmware; add `linux-firmware-bnx2` etc. as needed for specific NICs |
| `nodejs` | Required for Codex CLI; ~80 MB of the image |
| `ntfs-3g` | Large; exclude if you don't need NTFS support |
| `testdisk` | Useful for recovery; ~5 MB |
| `cryptsetup` | Required for persistence; ~3 MB |

### Image size targets

| Edition | Target size | With persistence |
|---|---|---|
| `codexos-lite` | ~120 MB | +64 MB (LUKS headers + config) |
| `codexos-lite-gui` | ~180 MB | +64 MB |
| `codexos-compat` | ~350 MB | +64 MB |
