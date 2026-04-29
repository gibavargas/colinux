# Disk Safety

This document provides the complete specification of CodexOS Lite's disk safety model — the most critical security feature of the appliance.

## Table of Contents

- [Philosophy](#philosophy)
- [Default Mount Behavior](#default-mount-behavior)
- [Read-Only First Policy](#read-only-first-policy)
- [Write Escalation Flow](#write-escalation-flow)
- [Safety Phrase System](#safety-phrase-system)
- [Destructive Operations](#destructive-operations)
- [Forensic Mode](#forensic-mode)
- [Boot Device Protection](#boot-device-protection)
- [Logging](#logging)
- [Emergency Procedures](#emergency-procedures)

---

## Philosophy

CodexOS Lite's primary use case involves connecting to machines with unknown disks — potentially containing valuable data, evidence, or critical system configurations. The disk safety model is built on a single principle:

> **Data is irreplaceable. Operations are not.**

Every disk operation starts from a position of maximum caution. Convenience is secondary to safety.

---

## Default Mount Behavior

When a disk or partition is detected, the default behavior is:

| Action | Default |
|---|---|
| Device visibility (`lsblk`, `blkid`) | ✅ Always available |
| Automatic mounting | ❌ Never automatic |
| Manual mount (read-only) | ✅ Available without confirmation |
| Manual mount (read-write) | ⚠️ Requires escalation (see below) |
| Filesystem modification | ⚠️ Requires escalation |
| Partition table modification | 🔒 Requires elevated escalation |
| Low-level block writes (`dd`) | 🔒 Requires elevated escalation |

### The mount wrappers

Mounting is done through `/usr/local/bin/codex-mount-ro` and `/usr/local/bin/codex-mount-rw`, which enforce these defaults:

```bash
# Read-only mount — always allowed
codex-mount-ro /dev/sdb1

# Read-write mount — triggers escalation flow
codex-mount-rw --confirm SERIAL /dev/sdb1
```

The wrapper:
1. Validates the device path (rejects `..`, symlinks outside `/dev/`).
2. Checks the device against the boot device list.
3. Checks if forensic mode is active.
4. For read-write: initiates the write escalation flow.
5. Logs the operation regardless of outcome.

---

## Read-Only First Policy

**All first mounts of any device are read-only.** This is not optional.

```
User request: "Mount /dev/sdb1"
System action: mount -o ro,noexec,nodev,nosuid /dev/sdb1 /mnt/target
```

Key flags applied to every mount:
- `ro` — read-only
- `noexec` — prevent execution of binaries on the mounted filesystem
- `nodev` — prevent device node interpretation
- `nosuid` — ignore SUID/SGID bits

To switch to read-write, the user must explicitly request it and complete the write escalation flow.

---

## Write Escalation Flow

### Standard write operations

```
┌─────────────────────────────────────────────────┐
│              Write Escalation Flow               │
│                                                   │
│  1. codex-mount-rw --confirm SERIAL /dev/sdb1   │
│                    │                              │
│  2. ┌─────────────▼──────────────┐               │
│  │   Boot device check           │               │
│  │   ├─ YES → ❌ DENIED (hard)   │               │
│  │   └─ NO  → continue           │               │
│  └─────────────┬─────────────────┘               │
│  3. ┌──────────▼──────────────┐                  │
│  │   Forensic mode check       │                  │
│  │   ├─ YES → ❌ DENIED         │                  │
│  │   └─ NO  → continue          │                  │
│  └──────────┬──────────────────┘                  │
│  4. ┌───────▼──────────────┐                     │
│  │   Confirmation prompt    │                     │
│  │   "Mount RW? [y/N]"      │                     │
│  │   ├─ NO → ❌ ABORTED      │                     │
│  │   └─ YES → continue       │                     │
│  └───────┬──────────────────┘                     │
│  5. ┌─────▼────────────────┐                      │
│  │   Safety phrase prompt   │                      │
│  │   "Type: crimson river   │                      │
│  │    fox"                  │                      │
│  │   ├─ MISMATCH → ❌ FAIL  │                      │
│  │   └─ MATCH → ✅ EXECUTE  │                      │
│  └─────┬────────────────────┘                      │
│  6. Log operation + mount RW                       │
│  7. Set 30-min auto-remount-RO timer              │
└─────────────────────────────────────────────────┘
```

### Timer behavior

After a successful write escalation:
- A 30-minute timer starts.
- After 30 minutes, the device is automatically remounted read-only.
- There is no way to disable the timer permanently.

---

## Safety Phrase System

### Purpose

The safety phrase prevents accidental confirmation — it requires the operator to read and type a specific phrase, proving deliberate intent rather than a reflexive "yes" or Enter key press.

### Phrase format

The active wrappers generate exact, operation-specific phrases with a random nonce, for example:

```text
I AUTHORIZE WRITE TO WD-WMC4T0123456 A1B2C3D4
I AUTHORIZE WIPE OF /dev/sdX A1B2C3D4
I AUTHORIZE RESIZE PERSISTENCE /dev/sdX3 A1B2C3D4
```

### Anti-automation measures

- The phrase changes on every request.
- The input must match exactly, including case, target, and nonce.
- The prompt is read from `/dev/tty`, so noninteractive AI sessions cannot complete the escalation by passing only command arguments.

---

## Destructive Operations

The following operations are classified as **destructive** and require the elevated escalation flow:

| Operation | Wrapper | Phrase Length | Additional Safeguards |
|---|---|---|---|
| Install to USB | `codex-install-usb` | Exact generated phrase | Target path and serial display |
| Install to PC | `codex-install-pc` | Exact generated phrase | Target path and serial display |
| Resize persistence | `codex-usb-persist resize` | Exact generated phrase | LUKS-only target check |
| Read-write mount | `codex-mount-rw` | Exact generated phrase | Serial confirmation, boot-device and forensic checks |

### Destructive escalation flow

```
1. Display target device path, model, serial, size, and operation mode.
2. Require typing the target device path exactly.
3. Require typing the generated operation-specific phrase from `/dev/tty`.
4. Execute only the narrow wrapper operation.
5. Log timestamps, operation details, and target identifiers.
```

---

## Forensic Mode

Forensic mode provides the strongest disk safety guarantees. It is intended for evidence collection and data recovery scenarios.

### Activation

```bash
codexctl forensic on
# Output: FORENSIC MODE ENABLED
# - Non-boot block devices set read-only
# - Write operations blocked
# - Read-only imaging available
```

### Behavior

| Feature | State |
|---|---|
| Non-boot block devices | `blockdev --setro` applied |
| Device node permissions | Unchanged |
| Mount with write | ❌ Blocked by `codex-mount-rw` and by block-device read-only state |
| Mount read-only | ✅ Allowed |
| Disk reads and user-space copying | ✅ Allowed from read-only mounts |
| Write escalation | ❌ Bypassed — forensic lock takes precedence |
| Persistent lock | Stored in `/run/codex/forensic.lock` and `/persist/state/forensic.lock` |

### Deactivation

```bash
codexctl forensic off
# Output: "Type this exact phrase to disable forensic mode:"
# After correct phrase:
# FORENSIC MODE DISABLED
# - Block devices returned to read-write mode
# - Normal safety model restored
```

Deactivation requires an interactive generated phrase and logs the event.

---

## Boot Device Protection

The boot device (the USB drive or medium from which CodexOS Lite booted) receives special, non-bypassable protection:

1. **Identification**: Wrappers resolve the root device through `/proc/cmdline`, `findmnt`, and parent-device lookup.
2. **Hard exclusion**: Read-write mount requests and forensic block-device changes skip or deny the boot device.
3. **Read-only system**: The base system is delivered as a read-only image with mutable state separated into encrypted persistence.
4. **No write escalation override**: Shipping installers and write-mount wrappers have no noninteractive confirmation bypass.

This is the one absolute, non-negotiable safety rule in CodexOS Lite.

---

## Logging

Privileged disk operations are logged to `/persist/logs/disk-actions.log`:

```
2025-06-15 14:23:01 [INFO] disk-inventory: scan completed, 3 devices found
2025-06-15 14:23:15 [INFO] codex-mount-ro: /dev/sdb1 mounted RO on /mnt/disks/by-device/sdb1 by codex
2025-06-15 14:25:30 [WARN] codex-mount-rw: write request for /dev/sdb1
2025-06-15 14:25:32 [INFO] codex-mount-rw: write escalation confirmed for /dev/sdb1
2025-06-15 14:25:32 [INFO] codex-mount-rw: /dev/sdb1 mounted RW on /mnt/disks/by-device/sdb1, timer=1800s
2025-06-15 14:55:32 [INFO] codex-mount-rw: auto-remount-RO timer expired for /dev/sdb1
2025-06-15 14:55:32 [INFO] codex-mount-rw: /dev/sdb1 remounted RO on /mnt/disks/by-device/sdb1
```

### Log format

```
YYYY-MM-DD HH:MM:SS [LEVEL] component: message
```

### Levels

- `INFO` — normal operations
- `WARN` — write requests, escalations
- `ERROR` — failed operations, safety violations
- `CRITICAL` — attempted boot device access, forensic mode bypass

### Retention

- Logs are kept for 30 days by default (configurable in `/etc/config/auto-update.conf`).
- Older logs are compressed with `gzip`.
- Logs are stored in the encrypted persistence partition.

---

## Emergency Procedures

### Something is writing to a disk it shouldn't

1. **Immediately freeze all block devices:**
   ```bash
   codexctl forensic on
   ```
   This runs `blockdev --setro` on all block devices except the boot device.

2. **Activate forensic mode:**
   ```bash
   codexctl forensic on
   ```

3. **Check logs:**
   ```bash
   codexctl logs --last 50
   ```

### Boot device seems to have been modified

1. **Don't panic.** The boot device runs from a squashfs overlay — the base filesystem is read-only.
2. **Check the overlay:**
   ```bash
   mount | grep overlay
   ```
3. **Reboot to clear any overlay modifications.**
4. **Report the incident** if you suspect a safety bypass.

### Lost the persistence passphrase

1. There is **no recovery mechanism** for a lost LUKS passphrase.
2. You can reset persistence by booting with the `nopersist` kernel parameter:
   ```
   boot: codexos nopersist
   ```
3. Then create a new persistence partition with `codex-install-usb` or `codex-usb-persist`.

### Immediate shutdown

```bash
# Clean shutdown (waits for operations to complete)
codexctl shutdown

# Emergency shutdown (immediate power-off)
codexctl emergency-shutdown
```
