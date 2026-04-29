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
