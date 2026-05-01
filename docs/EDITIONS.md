# Editions

CoLinux Lite ships in multiple editions to suit different hardware and use cases. All editions share the same disk safety model, Codex CLI integration, and persistence system.

## Edition Comparison

| Feature | colinux-lite | colinux-lite-gui | colinux-compat | colinux-desktop |
|---|---|---|---|---|
| **Status** | ✅ Stable | 🧪 Experimental | 🧪 Experimental | 📋 Planned |
| **Base distro** | Alpine Linux 3.19+ | Alpine Linux 3.19+ | Debian 12 (bookworm) | Alpine Linux 3.19+ |
| **Boot time** | ~8 seconds | ~12 seconds | ~15 seconds | ~20 seconds |
| **Image size** | ~120 MB | ~180 MB | ~350 MB | ~500 MB (est.) |
| **RAM minimum** | 512 MB | 1 GB | 1 GB | 2 GB |
| **Interface** | TTY (agetty) | cage + sway + foot | TTY (agetty) | GNOME + Electron |
| **Display required** | No | Yes | No | Yes |
| **Disk safety** | Full | Full | Full | Full |
| **Persistence** | LUKS | LUKS | LUKS | LUKS |
| **Codex CLI** | Yes | Yes | Yes | Yes |
| **codexctl** | Yes | Yes | Yes | Yes |
| **Forensic mode** | Yes | Yes | Yes | Yes |
| **Target** | USB sticks, headless servers | Laptops, workstations with display | Machines incompatible with Alpine | Full desktop experience |

---

## colinux-lite

The default and recommended edition. A headless TTY appliance that boots directly into a Codex CLI session.

### What it includes

- Alpine Linux base (busybox, musl, OpenRC)
- Linux LTS kernel
- Codex CLI (Node.js runtime)
- Disk tools: `lsblk`, `parted`, `fdisk`, `fsck`, `ntfs-3g`, `cryptsetup`, `mdadm`, `testdisk`
- Network: `dhcpcd`, `iwd` (WiFi), `openssh`, `curl`
- Utilities: `jq`, `less`, `htop`, `vim`
- `codexctl` control surface
- All disk safety wrappers (`safe-mount`, `safe-write`, `disk-inventory`)
- OpenRC init scripts (firstboot, disk-inventory, auto-update)

### Use cases

- Bootable USB for AI-assisted system administration
- Data recovery and forensic imaging
- Headless server deployment and configuration
- Network diagnostics and repair
- Infrastructure automation via Codex CLI

### Build

```bash
sudo ./build.sh
# or explicitly:
sudo ./build.sh --edition colinux-lite
```

### First boot

```
[    0.000000] Linux version 6.6.x ...
[    4.123456] CoLinux Lite v0.1.0
[    5.000000] Starting OpenRC ...
[    6.500000] Network: eth0 connected (DHCP)
[    7.000000] Codex CLI v1.0.0 ready.

codex> _
```

---

## colinux-lite-gui

An experimental edition that adds a minimal graphical interface on top of the TTY edition. Uses [cage](https://github.com/Hjdskes/cage) (a Wayland kiosk compositor) running [sway](https://swaywm.org/) with a fullscreen [foot](https://codeberg.org/dnkl/foot) terminal.

### What it includes

- Everything in `colinux-lite`
- cage (kiosk Wayland compositor)
- sway (tiling Wayland compositor)
- foot (terminal emulator)
- meson, wayland-protocols (build deps)
- Video drivers: `mesa-dri-gallium`, `linux-firmware` (full)

### Behavior

- Boots to a black screen with a fullscreen terminal.
- The terminal runs Codex CLI identically to the TTY edition.
- No window decorations, no taskbar, no escape from the terminal.
- Keyboard shortcuts: none (by design — prevents accidental escape).
- To exit: `codexctl shutdown` or Ctrl+Alt+Delete.

### Use cases

- Machines without serial console access
- Workshops and demonstrations
- Users uncomfortable with pure TTY environments
- Laptop-based field work

### Build

```bash
sudo ./build.sh --edition colinux-lite-gui
```

### Known issues

- Some GPU drivers are missing; may need to add vendor-specific firmware.
- Wayland compositor may fail on very old hardware (pre-2012).
- Touch input is not supported.
- Screen resolution defaults to the display's native resolution; no scaling options yet.

---

## colinux-compat

A Debian-based edition for hardware that is incompatible with Alpine Linux (primarily due to kernel module or firmware issues).

### What it includes

- Debian 12 (bookworm) minimal base
- Linux kernel from Debian (6.1 LTS)
- Codex CLI (Node.js from NodeSource)
- Disk tools: same set as `colinux-lite` (Debian package equivalents)
- Network: `networkd`, `wpa_supplicant`, `openssh`, `curl`
- `systemd` (replaces OpenRC)
- `codexctl` and all disk safety wrappers (adapted for systemd)

### What's different from colinux-lite

| Aspect | colinux-lite | colinux-compat |
|---|---|---|
| Init system | OpenRC | systemd |
| Package manager | `apk` | `apt` |
| Base size | ~120 MB | ~350 MB |
| Boot time | ~8s | ~15s |
| Kernel | Alpine LTS | Debian LTS |

### Why Debian?

Some hardware — particularly certain Wi-Fi adapters, Thunderbolt controllers, and GPU devices — require proprietary firmware or kernel modules that are only available in Debian's non-free repositories. This edition trades size and boot speed for hardware compatibility.

### Use cases

- Laptops with Broadcom Wi-Fi chips
- Machines requiring proprietary GPU drivers (NVIDIA)
- Environments where Debian is required for compliance
- Testing and development on Debian-based infrastructure

### Build

```bash
sudo ./build.sh --edition colinux-compat
```

### Notes

- The systemd init scripts are translations of the OpenRC scripts.
- The disk safety model is identical — same wrappers, same escalation flow.
- `codexctl` works the same way; systemd services replace OpenRC services.
- Auto-updates use systemd timers instead of cron.

---

## colinux-desktop

A planned edition that provides a full desktop environment with an Electron-based Codex Desktop application.

### Planned features

- GNOME or KDE Plasma desktop environment
- Electron-based Codex Desktop app (full UI for Codex CLI)
- File manager with Codex integration (right-click → "Ask Codex")
- System monitor dashboard
- Disk management GUI (with safety model integration)
- Browser for OpenAI API documentation
- Screenshot and clipboard integration with Codex

### Target audience

- Users who prefer a graphical environment
- Development teams using Codex for collaborative coding
- Educational settings
- Users who need concurrent terminal + GUI workflows

### Status

📋 **Planned for v1.2.** Contributions welcome. See `CONTRIBUTING.md` for guidelines.

### Estimated specs

- Image size: ~500 MB
- RAM minimum: 2 GB (4 GB recommended)
- Boot time: ~20 seconds
- Disk footprint: ~1.2 GB installed

---

## Choosing an Edition

```
Need a bootable USB for system administration?
└─► colinux-lite ✅

Have a display and want a terminal but no desktop?
└─► colinux-lite-gui 🧪

Alpine doesn't support your hardware?
└─► colinux-compat 🧪

Want a full desktop with Codex integration?
└─► colinux-desktop 📋 (not yet available)
```

### Recommendation

Start with **colinux-lite**. It's the smallest, fastest, and most tested edition. If you encounter hardware issues, try **colinux-compat**.
