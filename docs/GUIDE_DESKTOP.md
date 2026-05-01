# CoLinux Desktop Edition — User Guide

> **CoLinux Desktop** is the full graphical edition of CoLinux, featuring an XFCE4 desktop environment with the Codex Desktop (Electron) app pre-installed. It boots from USB, runs entirely in RAM for safety, and provides automatic updates for both the Debian system and the OpenAI Codex application.

---

## 📋 Table of Contents

1. [Overview](#overview)
2. [System Requirements](#system-requirements)
3. [Installation Methods](#installation-methods)
4. [First Boot Setup](#first-boot-setup)
5. [Using Codex Desktop](#using-codex-desktop)
6. [Network Setup](#network-setup)
7. [Disk Operations](#disk-operations)
8. [Auto-Update System](#auto-update-system)
9. [Persistent Storage](#persistent-storage)
10. [Troubleshooting](#troubleshooting)

---

## Overview

CoLinux Desktop provides a complete Linux desktop experience tailored for OpenAI Codex:

| Feature | Details |
|---|---|
| **Base System** | Debian Bookworm (stable) |
| **Desktop** | XFCE4 (lightweight) |
| **Codex App** | Electron-based Desktop GUI |
| **Display Manager** | LightDM (auto-login) |
| **Network** | NetworkManager (Wi-Fi + Ethernet) |
| **Updates** | Automatic (4-hour interval) |
| **Persistence** | Encrypted overlay (`/persist`) |
| **Disk Safety** | Read-only mount model |

---

## System Requirements

### Minimum
- **CPU**: x86_64 (64-bit), 1 GHz dual-core
- **RAM**: 2 GB
- **Storage**: 4 GB USB drive (8 GB recommended)
- **Boot**: BIOS or UEFI (Secure Boot supported)

### Recommended
- **CPU**: x86_64, 2 GHz quad-core or better
- **RAM**: 4 GB+
- **Storage**: 16 GB USB drive
- **GPU**: Intel/AMD (NVIDIA supported with proprietary drivers)
- **Network**: Wi-Fi (Intel, Atheros, Broadcom) or Ethernet

### Hardware Support
- **Wi-Fi**: Intel (iwlwifi), Atheros, Broadcom (via `broadcom-sta-dkms`)
- **GPU**: Intel HD/Iris, AMD Radeon (mesa), NVIDIA (proprietary)
- **Storage**: USB 2.0/3.0, SATA, NVMe
- **Input**: USB keyboards/mice, trackpads (synaptics/libinput)

---

## Installation Methods

### Method 1: USB Drive (Recommended)

```bash
# On Linux/macOS
sudo dd if=colinux-desktop-YYYYMMDD.iso of=/dev/sdX bs=4M status=progress && sync
```

Replace `/dev/sdX` with your USB device (find it with `lsblk`).

**⚠️ WARNING**: `dd` will erase all data on the target device. Double-check the device name.

### Method 2: Virtual Machine

**QEMU/KVM:**
```bash
qemu-system-x86_64 \
    -m 4096 \
    -smp 2 \
    -cdrom colinux-desktop-YYYYMMDD.iso \
    -boot d \
    -enable-kvm \
    -net nic -net user
```

**VirtualBox:**
1. Create new VM → Type: Linux → Version: Debian (64-bit)
2. RAM: 2048 MB+ → CPU: 2+ cores
3. Storage: Mount ISO on virtual CD drive
4. Network: NAT or Bridged Adapter
5. Boot and install

**VMware:**
1. Create VM → Guest OS: Debian 12.x 64-bit
2. Firmware: UEFI (for Secure Boot testing)
3. RAM: 2048 MB+
4. Mount ISO and boot

### Method 3: Direct Boot (Advanced)

Flash to internal drive using the raw USB image:
```bash
sudo dd if=colinux-desktop-YYYYMMDD.img.gz of=/dev/nvme0n1 bs=4M status=progress && sync
```

---

## First Boot Setup

### Boot Sequence

1. **BIOS/UEFI** → Select USB drive or set as boot device
2. **GRUB** → Choose "CoLinux Desktop (Live)" (or "Safe Graphics" if display issues)
3. **System loads** into RAM (may take 30-60 seconds)
4. **LightDM** auto-logs in as the `codex` user
5. **XFCE4 desktop** appears
6. **First-boot script** runs automatically (sets up persistence, updates, etc.)

### Initial Configuration

The first-boot script automatically:
- Creates encrypted persistent storage on available disk space
- Sets up the `codex` user environment
- Triggers initial Codex Desktop setup
- Enables auto-update timer
- Generates SSH keys

You'll see a notification when setup is complete.

### Persistence Setup

On first boot, you'll be prompted to set up encrypted storage:
1. A partition is created (or you can select an existing one)
2. You set an encryption passphrase (minimum 8 characters)
3. The partition is formatted as ext4 + LUKS
4. Mounted at `/persist` with directories for data, configs, logs, backups

**If you skip persistence**: The system runs entirely in RAM — all changes are lost on reboot.

---

## Using Codex Desktop

### Starting the App

Codex Desktop starts automatically after boot. If it doesn't:

```bash
# Via command line
codexctl desktop start

# Via systemd
sudo systemctl start codex-desktop.service

# Manual launch
/opt/codex-desktop/codex-desktop
```

### Codex CLI

The Codex CLI is also available in the terminal:

```bash
# Start Codex in terminal mode
codex

# Check version
codex --version

# With options
codex --model gpt-4o --approval-mode full-auto "Explain this code"
```

### Configuration

Codex configuration is stored in `/persist/config/codex/`:

```bash
# Edit Codex configuration
vim /persist/config/codex/config.json

# Or use environment variable
export CODEX_CONFIG_DIR=/persist/config/codex
```

### Restarting/Stopping

```bash
# Restart the desktop app
codexctl desktop restart

# Stop completely
codexctl desktop stop
```

---

## Network Setup

### Ethernet

Automatically configured by NetworkManager. Plug in a cable and it should work immediately.

### Wi-Fi

1. Click the Network Manager icon in the system tray (top-right)
2. Select your Wi-Fi network
3. Enter the password
4. Wait for connection

**Command line:**
```bash
# List available networks
codexctl network scan

# Connect to a network
codexctl network connect "MyNetwork"

# List active connections
codexctl network list
```

### Troubleshooting

```bash
# Check connection
ping -c 3 8.8.8.8

# Restart NetworkManager
sudo systemctl restart NetworkManager

# Check Wi-Fi radio
nmcli radio wifi

# Enable if off
nmcli radio wifi on

# Check adapter
ip link show
```

---

## Disk Operations

### ⚠️ Disk Safety Model

**All disks are mounted read-only by default.** This protects user data from accidental modification.

### Viewing Disks

```bash
# List all block devices
codexctl disks

# Or use lsblk directly
lsblk -f
```

### Read-Only Mount

To safely inspect a disk:

```bash
# Mount a device read-only
codexctl mount-ro /dev/sdb1

# Or use the wrapper directly
codex-mount-ro /dev/sdb1 /mnt/usb

# Unmount
sudo umount /media/codex/sdb1
```

### Creating Backups

**Always backup before any write operations:**

```bash
# Create backup (saved to /persist/backups/)
codexctl backup /dev/sdb

# Custom output location
codexctl backup /dev/sdb /persist/backups/mydisk.img

# Verify a backup
codexctl backup --verify /persist/backups/mydisk.img
```

### GUI Tools

- **GParted** (Applications → System → GParted) — Partition editor
- **Thunar** (File Manager) — Auto-mounts removable drives via udisks2
- **Disks** (gnome-disk-utility if installed) — Disk management

---

## Auto-Update System

### How It Works

CoLinux Desktop has a two-tier update system:

```
┌─────────────────────────────────────┐
│     codex-update.timer (4h)         │
│             │                       │
│     ┌───────┴───────┐               │
│     ▼               ▼               │
│ System Updates   Codex Desktop      │
│ (Debian apt)     (Electron + CLI)   │
│ security-only    latest releases    │
└─────────────────────────────────────┘
```

1. **System Updates** (`codex-system-autoupdate`): Debian security updates only
2. **Codex Desktop Updates** (`codex-desktop-autoupdate`): Electron wrapper + Codex binary

### Configuration

Edit `/etc/codex-auto-update.conf`:

```ini
# Enable/disable auto-updates
enabled=true

# Check interval (hours)
interval=4

# Update channels: stable | preview
codex_desktop_channel=stable
codex_cli_channel=stable

# Auto-install or notify only
auto_install=true

# Show desktop notifications
notify=true

# Number of rollback points to keep
rollback_count=3

# System update scope: security-only | all
system_updates=security-only
```

### Manual Updates

```bash
# Check for updates
codexctl update --check

# Force update
codexctl update --force

# System updates only
codex-system-autoupdate --full

# Codex Desktop only
codex-desktop-autoupdate --force

# Rollback to previous version
codexctl rollback
```

### Rollback

The system keeps the last 3 versions of the Codex Desktop app:

```bash
# Roll back to previous version
codexctl rollback

# Check rollback points
ls /var/lib/codex-desktop/rollback/
```

### Update Notifications

Desktop notifications appear for:
- New updates available
- Updates in progress
- Update success/failure
- Rollback completion

---

## Persistent Storage

### Directory Structure

```
/persist/
├── .first-boot-done        # First boot marker
├── logs/                   # Application logs
├── data/                   # User data files
├── backups/                # Disk backups
├── state/                  # System state
│   ├── codex-desktop/      # Desktop app state
│   └── disk/               # Disk inventory
├── config/                 # Configuration files
│   └── codex/              # Codex CLI config
├── ssh/                    # SSH keys
├── home/                   # Persisted home directories
│   └── codex/
│       ├── Documents/
│       ├── Downloads/
│       ├── Desktop/
│       ├── .config/
│       └── .local/
└── .gnupg/                 # GPG keys
```

### Creating Persistence on USB

After writing the ISO to USB, create a persistence partition:

```bash
# In a running CoLinux session or any Linux system:
# 1. Find the USB drive
lsblk

# 2. Create a new partition for persistence
sudo parted /dev/sdX -- mkpart primary ext4 4GiB 100%
sudo mkfs.ext4 -L codex-persist /dev/sdX2

# 3. (Optional) Encrypt it
sudo cryptsetup luksFormat /dev/sdX2 -L codex-persist
sudo cryptsetup open /dev/sdX2 codex-persist

# 4. The live system will auto-detect and use this partition
```

### Checking Persistence

```bash
# Check if persistence is active
df -h /persist

# Check size
du -sh /persist/*
```

---

## Troubleshooting

### Boot Issues

**Black screen after GRUB:**
```bash
# Reboot and select "Safe Graphics" from GRUB menu
# If that works, add nomodeset to kernel params permanently
```

**Secure Boot issues:**
- CoLinux supports Secure Boot via shim-signed
- If you get a signature error, disable Secure Boot in BIOS/UEFI
- Report the issue: the shim signature may need updating

**USB not booting:**
- Verify the ISO was written correctly: `dd if=colinux-desktop.iso | md5sum`
- Try a different USB port (USB 2.0 is most compatible)
- Check BIOS boot order — some systems require "USB HDD" vs "USB FDD"

### Display Issues

**Wrong resolution:**
```bash
# Set resolution with xrandr
xrandr --output HDMI-1 --mode 1920x1080

# Or configure in XFCE: Settings → Display
```

**No display at all:**
- Try "Safe Graphics" boot option
- Check GPU compatibility: `lspci -k | grep -A 2 -E "VGA|3D"`
- Install NVIDIA drivers: `sudo apt install nvidia-driver`

### Network Issues

**Wi-Fi not detected:**
```bash
# Check if Wi-Fi adapter is visible
ip link show

# Check firmware
dmesg | grep -i firmware

# Install additional firmware
sudo apt install firmware-iwlwifi firmware-atheros
sudo modprobe <driver_name>
```

**No internet:**
```bash
# Check DNS
resolvectl status

# Try manual DNS
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf

# Restart networking
sudo systemctl restart NetworkManager
```

### Codex Desktop Issues

**App won't start:**
```bash
# Check for errors
journalctl -u codex-desktop.service --no-pager -n 50

# Check Electron dependencies
ldd /opt/codex-desktop/codex-desktop 2>&1 | grep "not found"

# Reinstall Electron dependencies
sudo apt install libgbm1 libnss3 libatk-bridge2.0-0 libdrm2 libxkbcommon0 libasound2

# Re-run setup
codexctl setup
```

**Update failures:**
```bash
# Check update logs
codexctl logs desktop
codexctl logs system

# Force a fresh update
codexctl update --force

# Check GitHub API access
curl -s https://api.github.com/repos/openai/codex/releases/latest | jq .tag_name

# If rate-limited, wait and retry
```

### General System Issues

**System feels slow:**
- Minimum 2 GB RAM required; 4 GB recommended
- Check memory: `free -h`
- Close unused applications
- Consider disabling desktop effects: Settings → Window Manager Tweaks → Compositor

**Disk full:**
```bash
# Check usage
df -h

# Clean old logs
sudo journalctl --vacuum-size=50M

# Clean old backups
ls -la /persist/backups/
# Remove old backups as needed

# Clean apt cache
sudo apt clean
```

### Getting Help

```bash
# System status overview
codexctl status

# Check all logs
codexctl logs

# Check specific service
codexctl logs journal

# Reset everything (last resort)
sudo rm /persist/.first-boot-done
sudo systemctl restart codex-firstboot.service
```

---

## Quick Reference

| Command | Description |
|---|---|
| `codexctl status` | System status overview |
| `codexctl update` | Check and install updates |
| `codexctl update --force` | Force all updates |
| `codexctl rollback` | Roll back Codex Desktop |
| `codexctl disks` | Show disk inventory |
| `codexctl mount-ro /dev/sdX` | Safe read-only mount |
| `codexctl backup /dev/sdX` | Create disk backup |
| `codexctl desktop start` | Start Codex Desktop |
| `codexctl network scan` | Scan Wi-Fi networks |
| `codexctl network connect SSID` | Connect to Wi-Fi |
| `codexctl logs` | View all logs |
| `codexctl version` | Show version info |
| `codexctl help` | Show help |

---

*CoLinux Desktop Edition v1.0.0 — Built with Debian Bookworm, XFCE4, and Electron*
