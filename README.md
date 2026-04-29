<p align="center">
  <img src="docs/assets/logo.svg" alt="CodexOS Lite" width="320"/>
</p>

<h1 align="center">CodexOS Lite</h1>

<p align="center">
  <strong>A bootable Linux appliance whose main interface is Codex CLI.</strong><br/>
  Plug in a USB, boot it, and talk to your machines.
</p>

<p align="center">
  <a href="#features">Features</a> •
  <a href="#editions">Editions</a> •
  <a href="#for-humans">For Humans</a> •
  <a href="#for-ai-agents">For AI Agents</a> •
  <a href="#quick-start">Quick Start</a> •
  <a href="#building-from-source">Build</a> •
  <a href="#installation">Install</a> •
  <a href="docs/DISK_SAFETY.md">Disk Safety</a> •
  <a href="docs/SECURITY.md">Security</a> •
  <a href="LICENSE">License</a>
</p>

---

## What is CodexOS Lite?

CodexOS Lite is a minimal, bootable Linux distribution built on Alpine Linux that boots directly into [OpenAI Codex CLI](https://github.com/openai/codex-cli). There's no desktop environment to configure, no package manager to wrestle with — just a terminal with an AI coding agent that has the tools to inspect disks, recover files, diagnose systems, and automate infrastructure, all through natural language.

Think of it as a *rescue USB for the AI age*.

- **Boot from USB** on any x86\_64 PC — no installation required.
- **Talk to Codex** immediately after boot — it's the only UI.
- **Safe disk access** by default: everything mounts read-only, writes require explicit multi-step confirmation.
- **Encrypted persistence** via LUKS — your Codex sessions, logs, and configuration survive reboots.
- **~120 MB base image** — fits on any USB drive, boots in seconds.

CodexOS Lite is not a general-purpose Linux distribution. It's a purpose-built appliance for AI-assisted system administration, data recovery, and infrastructure automation.

---

## Features

- ⚡ **Fast boot** — Alpine Linux + busybox init gets you to a shell in under 10 seconds.
- 🛡️ **Safe disk control** — all block devices mount read-only by default; writes require interactive confirmation with a typed safety phrase.
- 🔒 **Encrypted persistence** — optional LUKS partition stores Codex config, history, and custom tools across reboots.
- 📦 **Minimal footprint** — ~120 MB compressed base image, ~300 MB uncompressed.
- 🔧 **Disk tools pre-installed** — `lsblk`, `parted`, `fdisk`, `fsck`, `testdisk`, `ntfs-3g`, `ext4/dosfstools`, `cryptsetup`, `mdadm`.
- 🤖 **Codex CLI integration** — OpenAI Codex CLI runs as the primary interface with pre-configured safe wrappers.
- 📋 **codexctl** — a control surface for managing Codex sessions, disk state, and appliance configuration.
- 🖥️ **Multiple editions** — choose from headless TTY, GUI (cage/sway), or Debian-based compat builds.
- 🔍 **Forensic mode** — block-level imaging with write-protect guarantees and SHA-256 verification.
- 🔄 **Auto-updates** — periodic Codex CLI version checks via cron with configurable channels.
- 📝 **Comprehensive logging** — all disk operations, Codex commands, and system events logged to `/persist/logs/`.

## Screenshots

> 📷 *Screenshots coming soon.*

| Boot screen | Codex CLI session | Disk inspection |
|---|---|---|
| *(placeholder)* | *(placeholder)* | *(placeholder)* |

## Editions

CodexOS Lite ships in multiple editions for different use cases:

| Edition | Base | UI | Target | Status |
|---|---|---|---|---|
| `codexos-lite` | Alpine Linux | TTY (agetty) | USB sticks, headless machines | ✅ Stable |
| `codexos-lite-gui` | Alpine Linux | cage + sway + foot | Machines with display output | 🧪 Experimental |
| `codexos-compat` | Debian minimal | TTY (agetty) | Hardware incompatible with Alpine | 🧪 Experimental |
| `codexos-desktop` | Alpine Linux | GNOME + Electron Codex | Full desktop experience | 📋 Planned |

See [`docs/EDITIONS.md`](docs/EDITIONS.md) for a detailed comparison.

## Quick Start

### 1. Build the image

```bash
# On an Alpine Linux host:
cd ~/CoLinux/codexos
sudo ./build.sh
```

### 2. Test with QEMU

```bash
./scripts/qemu-test.sh dist/codexos-lite.iso
```

### 3. Write to a USB drive

```bash
sudo dd if=dist/codexos-lite.iso of=/dev/sdX bs=4M status=progress && sync
```

> ⚠️ Replace `/dev/sdX` with your actual USB device. **This will erase all data on the target drive.**

### 4. Boot it

Insert the USB, boot from it, and you'll be dropped into a Codex CLI session. Start typing.

## Requirements

### To build

- **Build host**: Alpine Linux 3.19+ (recommended) or Docker with Alpine container
- **Disk space**: ~2 GB for build artifacts
- **Tools**: `apk-tools`, `mkinitfs`, `syslinux`, `xorriso`, `mksquashfs`, `cryptsetup`
- **Optional**: QEMU for testing (`qemu-system-x86_64`)

### To run

- **x86\_64 PC** with USB boot support (UEFI or legacy BIOS)
- **RAM**: 2 GB minimum, 4 GB recommended
- **Storage**: 4 GB+ USB drive (8 GB recommended for persistence)
- **Network**: Internet access required for Codex CLI (OpenAI API key)

## Project Structure

```
codexos/
├── README.md                          # This file
├── LICENSE                            # MIT License
├── .gitignore                         # Git ignore rules
├── Makefile                           # Top-level build orchestration
├── build.sh                           # Main build script
├── profiles/
│   ├── alpine/
│   │   ├── packages.list              # Alpine packages to install
│   │   ├── mkimg.conf                 # mkimage profile config
│   │   └── overlay/                   # Overlay filesystem
│   │       ├── etc/
│   │       │   ├── init.d/            # OpenRC init scripts
│   │       │   │   ├── codex-firstboot
│   │       │   │   ├── codex-disk-inventory
│   │       │   │   └── codex-auto-update
│   │       │   ├── config/            # Configuration files
│   │       │   │   └── auto-update.conf
│   │       │   ├── codex-update-crontab
│   │       │   └── doas.conf          # doas privilege rules
│   │       ├── usr/
│   │       │   ├── local/bin/         # Custom scripts
│   │       │   │   ├── codexctl       # Codex control surface
│   │       │   │   ├── safe-mount     # Safe mount wrapper
│   │       │   │   ├── safe-write     # Write escalation gate
│   │       │   │   ├── disk-inventory # Disk inventory collector
│   │       │   │   └── first-boot.sh  # First-boot setup
│   │       │   └── share/codexos/     # Shared resources
│   │       │       └── safety-phrases # Safety phrase bank
│   │       └── var/                   # Runtime state
│   └── debian/                        # Debian-based compat profile
├── scripts/
│   ├── qemu-test.sh                   # QEMU test runner
│   ├── usb-write.sh                   # Safe USB imaging script
│   └── create-persistence.sh          # LUKS persistence setup
├── docs/
│   ├── SECURITY.md                    # Security documentation
│   ├── DISK_SAFETY.md                 # Disk safety model
│   ├── BUILD.md                       # Build instructions
│   └── EDITIONS.md                    # Edition comparison
└── tests/
    ├── disk-safety.bats               # Disk safety tests
    └── integration.bats               # Integration test suite
```

## Building from Source

See [`docs/BUILD.md`](docs/BUILD.md) for the full build guide. Here's the short version:

```bash
# Clone the repository
git clone https://github.com/colinux/codexos.git
cd codexos

# Build the default edition
sudo ./build.sh

# Build a specific edition
sudo ./build.sh --edition codexos-lite-gui

# Build with custom config
sudo ./build.sh --config my-build.conf

# The output image will be at dist/codexos-lite.iso
```

### Build configuration

Create a `build.conf` file in the project root to override defaults:

```bash
# build.conf
EDITION="codexos-lite"
OUTPUT_DIR="dist"
ENABLE_PERSISTENCE="true"
CODEX_VERSION="latest"
COMPRESSION="xz"
EXTRA_PACKAGES="vim htop tmux"
```

## Installation

### USB Drive (Live)

```bash
# Identify your USB drive
lsblk

# Write the image
sudo ./scripts/usb-write.sh /dev/sdX

# (Optional) Create encrypted persistence partition
sudo ./scripts/create-persistence.sh /dev/sdX
```

### PC Installation

CodexOS Lite is designed as a *live appliance* — it runs entirely from USB without touching the host machine's disks. There is no "install to disk" flow.

If you want persistent local storage:

1. Boot from the USB drive.
2. Run `sudo setup-persistence` to create an encrypted LUKS partition on a designated drive.
3. Your Codex config, session history, and logs will persist across reboots.

> 🔒 Persistence uses LUKS2 with AES-256-XTS. You'll set a passphrase on first setup.

## First Boot Experience

When you boot CodexOS Lite for the first time:

1. **Bootloader** — syslinux presents a brief boot menu (Live, Forensic, Debug).
2. **Kernel + initramfs** — boots into Alpine's initramfs, loads modules.
3. **Overlay mount** — the squashfs root filesystem is mounted read-only; an `overlayfs` tmpfs provides writable space.
4. **First-boot script** — if `/persist/.first-boot-done` doesn't exist:
   - Generates machine ID and host keys.
   - Initializes `/persist/` directory structure.
   - Prompts for OpenAI API key (stored in encrypted persistence).
   - Configures Codex CLI with safe defaults.
   - Sets up the cron auto-update job.
   - Creates the flag file.
5. **Codex CLI** — you're dropped into a Codex session. Start typing commands.

Subsequent boots skip the first-boot wizard and go straight to Codex.

## Disk Safety Model

CodexOS Lite treats **every disk as potentially valuable and dangerous by default**.

| Operation | Default | Escalation |
|---|---|---|
| List devices | ✅ Allowed | None |
| Read files | ✅ Allowed (read-only mount) | None |
| Mount filesystem | ⚠️ Read-only | Explicit write mount |
| Write/modify files | ❌ Blocked | Multi-step confirmation |
| Format/partition | ❌ Blocked | Multi-step + typed safety phrase |
| Block-level write (dd) | ❌ Blocked | Multi-step + typed safety phrase + timeout |
| Boot device operations | ❌ Always blocked | Cannot be escalated |

See [`docs/DISK_SAFETY.md`](docs/DISK_SAFETY.md) for the complete specification.

## Codex Control Surface (`codexctl`)

`codexctl` is the appliance management CLI:

```bash
# Check system status
codexctl status

# List detected disks
codexctl disks

# Mount a disk read-only
codexctl mount /dev/sdb1 /mnt/target

# Request write access (triggers interactive confirmation)
codexctl mount --write /dev/sdb1 /mnt/target

# Enter forensic mode (all disks read-only, immutable)
codexctl forensic on

# Create a disk image with verification
codexctl image /dev/sdb --output /persist/images/sdb.img

# Manage persistence
codexctl persistence setup /dev/sdc
codexctl persistence status

# Update Codex CLI
codexctl update --channel stable
```

## 🧑 For Humans

### Prerequisites

To use CodexOS Lite, you need:

- **A USB drive** — 4 GB minimum, 8 GB+ recommended (for persistence)
- **An x86_64 PC** with USB boot support (UEFI or legacy BIOS)
- **2 GB RAM** minimum (4 GB recommended)
- **Internet access** — required for OpenAI Codex CLI to function
- **An OpenAI API key** — you'll be prompted for it on first boot

To **build** from source, you also need:

- Docker (easiest) or an Alpine Linux 3.19+ host
- ~2 GB of free disk space

### Quick Start — Build with Docker in 3 Commands

```bash
# 1. Clone the repo
git clone https://github.com/gibavargas/codexos.git
cd codexos

# 2. Build the Docker image (this IS CodexOS — a full environment)
docker build -t codexos-lite .

# 3. Launch it
docker run -it --rm codexos-lite
```

That's it. You're inside CodexOS with all the disk tools, codexctl, and a shell. Run `codexctl status` to see system info.

For a bootable ISO instead:

```bash
# Build the Alpine ISO
docker run -it --rm -v "$PWD/dist:/dist" -w /build \
  alpine:3.21 \
  sh -c "apk add --no-cache bash curl git ca-certificates squashfs-tools xorriso grub-efi e2fsprogs dosfstools mtools qemu-utils openssl sgdisk && \
          ./scripts/build-alpine.sh --outdir /dist"
```

### Creating a Bootable USB

**Option A: `dd` (Linux/macOS)**

```bash
# Find your USB drive
lsblk

# Write the image (REPLACE /dev/sdX WITH YOUR DEVICE)
sudo dd if=dist/codexos-lite-x86_64-*.iso of=/dev/sdX bs=4M status=progress && sync

# Or use the safe helper script
sudo ./scripts/usb-write.sh /dev/sdX
```

> ⚠️ **This will erase all data on the target drive.** Double-check the device name.

**Option B: balenaEtcher (Windows/macOS/Linux)**

1. Download [balenaEtcher](https://balena.io/etcher/)
2. Select the ISO file
3. Select your USB drive
4. Click "Flash"

### First Boot Walkthrough

When you boot CodexOS Lite for the first time, here's what happens:

1. **Bootloader menu** — syslinux shows three options:
   - `Live` — normal boot (choose this)
   - `Forensic` — all disks forced read-only
   - `Debug` — verbose boot with shell fallback

2. **Kernel loads** — Alpine's initramfs boots in under 10 seconds

3. **First-boot wizard** runs automatically:
   ```
   === CodexOS Lite — First Boot Setup ===
   ? Enter your OpenAI API key: sk-...
   ✓ Codex CLI configured
   ? Set up encrypted persistence? (y/N):
   ```

4. **Codex CLI launches** — you see the Codex prompt:
   ```
   codex> 
   ```

5. **Start typing.** For example:
   ```
   codex> Show me what disks are attached
   codex> List all files on the second partition of /dev/sdb
   codex> What's the SMART health status of /dev/sda?
   ```

Subsequent boots skip the wizard and go straight to Codex.

### Using Codex (Basic Commands)

Codex CLI is a natural language interface. Here are things you can ask:

```
# System information
codex> What OS version are we running? What kernel?
codex> How much RAM and disk space is available?

# File operations
codex> List all files in /mnt/disks/by-device/sdb1
codex> Copy the photos folder from the USB drive to /persist/data/
codex> Find all .jpg files larger than 5MB on the mounted drive

# Disk operations
codex> Show me all attached block devices with their filesystems
codex> What's the partition table of /dev/nvme0n1?
codex> Check the filesystem health of /dev/sda1

# Recovery
codex> I accidentally deleted a file called report.docx — can you recover it?
codex> This NTFS drive won't mount, help me diagnose it

# Networking
codex> Scan the local network for devices
codex> Test if I can reach the internet
```

### Disk Operations

All disk operations go through `codexctl` for safety:

```bash
# See what's attached
codexctl disks

# Mount a drive read-only (safe, always allowed)
codexctl mount-ro /dev/sdb1
ls /mnt/disks/by-device/sdb1/

# Mount read-write (requires confirmation with device serial)
codexctl mount-rw --confirm "WD-WMC4T0123456" /dev/sdb1

# Copy files from a mounted drive to persistent storage
cp -r /mnt/disks/by-device/sdb1/photos /persist/data/

# Create a forensic disk image (with SHA-256 verification)
codexctl image /dev/sdb --output /persist/images/evidence.img

# Enter forensic mode (all operations read-only, immutable)
codexctl forensic on

# View mounted disks
mount | grep /mnt/disks
```

### Network Setup

```bash
# Check current network status
codexctl network

# Wired: usually auto-configured via DHCP
# If not, bring up the interface:
codexctl network up eth0

# Wireless: scan and connect
codexctl network scan
codexctl network connect "MyWiFi" "password123"

# Check connectivity
ping -c 3 8.8.8.8
curl -sS ifconfig.me
```

### Troubleshooting Common Issues

| Problem | Solution |
|---------|----------|
| Won't boot from USB | Check BIOS/UEFI boot order; try "USB HDD" or "UEFI: <drive>" |
| Black screen after boot | Reboot and select `Debug` from the boot menu; check graphics compatibility |
| No network | Run `codexctl network`; try `ip link` to see interfaces; check cable/WiFi |
| Codex says "API key invalid" | Run `setup-codex --key` to reconfigure your OpenAI API key |
| Can't write to USB drive | By design! Use `codexctl mount-rw --confirm <SERIAL> <device>` |
| Disk won't mount | Try `codexctl mount-ro /dev/sdXN` first; run `fsck /dev/sdXN` to check |
| Out of space on persistence | Run `df -h /persist`; clean up with `codexctl backup --list` |
| Slow boot | Check USB drive speed (USB 3.0+ recommended); try a different port |

### FAQ

**Q: Does CodexOS install anything on my computer?**
A: No. It runs entirely from the USB drive. Nothing is written to your internal disks unless you explicitly request it.

**Q: Can I use it without an OpenAI API key?**
A: You can use the shell and disk tools without an API key, but the Codex AI assistant requires one.

**Q: How do I update Codex CLI?**
A: Run `codexctl update` — it checks for new versions and updates automatically.

**Q: Can I run this in a virtual machine?**
A: Yes. `qemu-system-x86_64 -m 2048 -cdrom dist/codexos-lite-x86_64-*.iso -boot d` or use VirtualBox/VMware.

**Q: How do I set up persistence?**
A: Run `codexctl persist setup /dev/sdX` during a live session. It creates an encrypted partition for your config, logs, and data.

**Q: Is my API key stored securely?**
A: Yes. API keys are stored in `/persist/config/` with 0600 permissions, owned by the `codex` user. If using LUKS persistence, the key is encrypted on disk.

---

## 🤖 For AI Agents

### AGENTS.md — The Rules Codex Follows

CodexOS places an `AGENTS.md` file at `/workspace/AGENTS.md` on first boot. This file contains all operating rules that Codex must follow. Key rules:

1. **Disk Safety** — Never write to disks without explicit user confirmation. Always run `codex-disk-inventory` first.
2. **Read-First** — Mount unknown filesystems read-only before any write operations.
3. **Persistence Layout** — Use `/persist/` for all persistent data (`config/`, `data/`, `logs/`, `backups/`).
4. **Network** — Use `codex-network` for all network operations. Prefer wired over wireless.
5. **Logging** — All operations must be logged to `/persist/logs/` in format `YYYY-MM-DD HH:MM:SS [LEVEL] message`.
6. **Security** — Only `codex-*` commands are whitelisted in `doas.conf`. Never escalate outside these.
7. **Workspace** — `/workspace` is ephemeral. Persistent data goes to `/workspace/data` (bind-mounted from `/persist/data/`).

See the full [`AGENTS.md`](AGENTS.md) in the repository root.

### codexctl API Reference

`codexctl` is the primary control interface. All subcommands:

```bash
# System info
codexctl status                 # Human-readable status
codexctl status --json          # JSON output for programmatic use

# Version info
codexctl version                # Show CodexOS + Codex CLI versions

# Disk operations
codexctl disks                  # Disk inventory (human)
codexctl disks --json           # Disk inventory (JSON)

# Mounting
codexctl mount-ro /dev/sdb1     # Read-only mount (always safe)
codexctl mount-rw --confirm "SERIAL" /dev/sdb1 /mnt/target  # Read-write (requires confirmation)

# Persistence
codexctl persist                # Show persistence status
codexctl persist open /dev/sdX3 # Unlock LUKS persistence
codexctl persist close          # Lock persistence

# Updates
codexctl update                 # Update Codex CLI + Alpine packages
codexctl update --check         # Check for available updates

# Network
codexctl network                # Network status
codexctl network up eth0        # Bring up interface
codexctl network scan           # Scan WiFi networks

# Logs
codexctl logs                   # View system logs
codexctl logs --follow          # Tail logs

# Backups
codexctl backup                 # Create workspace backup
codexctl backup --list          # List existing backups

# Installation
codexctl install-usb /dev/sdX   # Install CodexOS to USB
codexctl install-pc             # Install to internal disk
```

### Programmatic Disk Operations (JSON Output)

For CI/CD and automation, use `--json` flags:

```bash
# Get system status as JSON
codexctl status --json
# Output:
# {
#   "codexos_version": "0.1.0",
#   "codex_cli": "codex 0.1.0",
#   "kernel": "6.6.x",
#   "arch": "x86_64",
#   "hostname": "codexos",
#   "uptime": "up 5 minutes",
#   "timestamp": "2025-01-15T10:30:00Z"
# }

# Get disk inventory as JSON
codexctl disks --json
# Output:
# {
#   "devices": [
#     {
#       "name": "/dev/sda",
#       "serial": "WD-WMC4T0123456",
#       "size": "500107862016",
#       "model": "WDC WD5000LPCX",
#       "partitions": [...],
#       "safety": "foreign_disk"
#     }
#   ]
# }

# Parse with jq
codexctl disks --json | jq '.devices[] | {name, size, safety}'
codexctl status --json | jq '.codex_cli'
```

### Building Custom Images Programmatically

**Docker build (recommended for CI):**

```bash
# Build with a specific Codex version
docker build \
  --build-arg CODEX_VERSION=0.1.0 \
  -t codexos-lite:custom .

# Run with persistent volume
docker run -it \
  -v ./my-data:/workspace/data \
  -e OPENAI_API_KEY=sk-... \
  codexos-lite:custom
```

**Alpine ISO build (in CI):**

```bash
# Build for x86_64
ARCH=x86_64 ALPINE_RELEASE=3.21 OUTDIR=./dist \
  bash scripts/build-alpine.sh

# Build for aarch64
ARCH=aarch64 ALPINE_RELEASE=3.21 OUTDIR=./dist \
  bash scripts/build-alpine.sh

# With specific Codex version
CODEX_VERSION=v0.1.0 ARCH=x86_64 bash scripts/build-alpine.sh
```

### Testing in CI/CD

```bash
# Run the test suite
make test

# Or directly with bats
bats tests/disk-safety.bats
bats tests/integration.bats

# Quick smoke test in Docker
docker run --rm codexos-lite codexctl version
docker run --rm codexos-lite codexctl status --json

# Test ISO in QEMU (headless)
qemu-system-x86_64 \
  -m 1024 \
  -nographic \
  -cdrom dist/codexos-lite-x86_64-*.iso \
  -boot d \
  -net nic \
  -net user &
sleep 30
# ... run tests against booted system ...
kill %1
```

### Integration Patterns

**Pattern 1: Automated data recovery pipeline**

```bash
# Boot CodexOS, mount evidence drive, image it, hash it
codexctl mount-ro /dev/sdb1
codexctl image /dev/sdb --output /persist/images/evidence-$(date +%Y%m%d).img
sha256sum /persist/images/evidence-*.img > /persist/images/evidence.sha256
```

**Pattern 2: CI/CD infrastructure tool**

```bash
# Use CodexOS in Docker as a Codex agent for infrastructure tasks
docker run -it --rm \
  -v ~/.ssh:/persist/ssh:ro \
  -e OPENAI_API_KEY=$OPENAI_API_KEY \
  codexos-lite \
  codex -q "Check the health of all disks on these servers: host1, host2, host3"
```

**Pattern 3: Batch processing with JSON output**

```bash
# Script: inventory-all-disks.sh
#!/bin/bash
codexctl disks --json | jq -r '.devices[].name' | while read dev; do
  echo "=== $dev ==="
  codexctl mount-ro "$dev" 2>/dev/null || continue
  echo "Mounted successfully"
  codexctl persist
done
```

**Pattern 4: Custom AGENTS.md for your workflow**

```bash
# Mount your custom rules
docker run -it --rm \
  -v ./my-agents.md:/workspace/AGENTS.md \
  -v ./scripts:/workspace/custom-tools \
  codexos-lite
```

---

## Contributing

Contributions are welcome! Please follow these guidelines:

1. **Fork** the repository and create a feature branch.
2. **Test** your changes — run the test suite (`make test`) and verify with QEMU.
3. **Document** — update docs for any behavioral changes.
4. **Keep it minimal** — this is a tiny appliance. Every byte counts. Justify new dependencies.
5. **Respect the safety model** — never bypass disk safety checks without explicit, documented rationale.
6. **Submit a PR** with a clear description of what changed and why.

### Code style

- Shell scripts: follow [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html).
- Init scripts: follow OpenRC conventions (see existing scripts).
- Python (if used): follow PEP 8 with `flake8`.

### Reporting issues

Open a GitHub issue with:
- CodexOS Lite edition and version.
- Hardware description (PC model, USB drive).
- Steps to reproduce.
- Expected vs. actual behavior.
- Relevant logs from `/persist/logs/`.

## License

CodexOS Lite is released under the [MIT License](LICENSE).

Copyright © 2025 CoLinux Project.

## Links

- **Codex CLI**: [github.com/openai/codex-cli](https://github.com/openai/codex-cli)
- **Alpine Linux**: [alpinelinux.org](https://alpinelinux.org)
- **OpenRC**: [github.com/OpenRC/openrc](https://github.com/OpenRC/openrc)
- **LUKS**: [cryptsetup.gitlab.io](https://gitlab.com/cryptsetup/cryptsetup)

---

<p align="center">
  <sub>Built with ❤️ by the <a href="https://github.com/colinux">CoLinux Project</a></sub>
</p>
