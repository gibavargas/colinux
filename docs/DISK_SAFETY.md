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

### The `safe-mount` wrapper

All mounting is done through `/usr/local/bin/safe-mount`, which enforces these defaults:

```bash
# Read-only mount — always allowed
safe-mount /dev/sdb1 /mnt/target

# Read-write mount — triggers escalation flow
safe-mount --write /dev/sdb1 /mnt/target
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
│  1. safe-mount --write /dev/sdb1 /mnt/target     │
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
- A warning is displayed at 5 minutes and 1 minute before expiry.
- The timer can be reset with `safe-mount --extend /dev/sdb1`.
- There is no way to disable the timer permanently.

---

## Safety Phrase System

### Purpose

The safety phrase prevents accidental confirmation — it requires the operator to read and type a specific phrase, proving deliberate intent rather than a reflexive "yes" or Enter key press.

### Phrase bank

Phrases are randomly selected from `/usr/share/codexos/safety-phrases`:

```
# 3-word phrases (standard operations)
crimson river fox
silent oak bridge
painted desert wind
iron mountain lake
frozen amber sky
...
```

Each phrase is:
- 3 words for standard operations (mount RW, file writes).
- 5 words for destructive operations (format, partition, dd).
- Generated from a pool of 200+ unique words.
- Displayed with randomized capitalization and spacing to prevent clipboard attacks.

### Anti-automation measures

- The phrase changes on every request.
- Phrases are never repeated within a session.
- The input is compared case-insensitively but must match exactly in word order.
- The phrase prompt includes a random prefix/suffix to make it harder to predict.

---

## Destructive Operations

The following operations are classified as **destructive** and require the elevated escalation flow:

| Operation | Wrapper | Phrase Length | Additional Safeguards |
|---|---|---|---|
| Format filesystem | `safe-write --format` | 5 words | Pre-image checksum |
| Create/modify partition table | `safe-write --partition` | 5 words | Pre-image checksum |
| Block-level write (`dd`) | `safe-write --block` | 5 words | Pre-image checksum + countdown |
| Delete files (`rm -rf`) | `safe-write --delete` | 5 words | File count preview |
| LUKS operations | `safe-write --crypt` | 5 words | Header backup prompt |

### Destructive escalation flow

```
1. Pre-operation SHA-256 checksum of target device (first 1 MiB)
2. Standard write escalation (confirmation + 5-word phrase)
3. 10-second countdown with progress bar:
   "Operation will execute in 10s... Press Ctrl+C to abort"
4. Final prompt: "LAST CHANCE. Type YES to proceed:"
5. Execute operation
6. Post-operation SHA-256 checksum
7. Log: timestamps, checksums (before/after), operator, operation details
```

---

## Forensic Mode

Forensic mode provides the strongest disk safety guarantees. It is intended for evidence collection and data recovery scenarios.

### Activation

```bash
codexctl forensic on
# Output: FORENSIC MODE ENABLED
# - All block devices frozen
# - Write operations blocked
# - Read-only imaging available
# - Watchdog active (60s interval)
```

### Behavior

| Feature | State |
|---|---|
| All block devices | `blockdev --setro` applied |
| Device node permissions | `0444` (read-only) |
| Mount with write | ❌ Blocked (kernel-level) |
| Mount read-only | ✅ Allowed |
| Disk imaging (read) | ✅ Allowed (with SHA-256) |
| Write escalation | ❌ Bypassed — forensic lock takes precedence |
| Forensic watchdog | Runs every 60 seconds, verifies all devices remain RO |

### Deactivation

```bash
codexctl forensic off
# Output: "Type: [5-word safety phrase]"
# After correct phrase:
# FORENSIC MODE DISABLED
# - Block devices unfrozen
# - Normal safety model restored
```

Deactivation requires a 5-word safety phrase and logs the event.

---

## Boot Device Protection

The boot device (the USB drive or medium from which CodexOS Lite booted) receives special, non-bypassable protection:

1. **Identification**: At boot, the device containing `/boot/` or the ISO label is recorded in `/run/codexos/boot-device`.
2. **Hard exclusion**: The boot device is **always excluded** from disk inventory, mount operations, and write operations.
3. **Immutable flag**: The boot device node is set to `immutable` via `chattr +i` (where supported by the filesystem).
4. **No override**: There is no flag, argument, or configuration that can disable boot device protection.

This is the one absolute, non-negotiable safety rule in CodexOS Lite.

---

## Logging

All disk operations are logged to `/persist/logs/disk-operations.log`:

```
2025-06-15 14:23:01 [INFO] disk-inventory: scan completed, 3 devices found
2025-06-15 14:23:15 [INFO] safe-mount: /dev/sdb1 mounted RO on /mnt/target by codex
2025-06-15 14:25:30 [WARN] safe-mount: write request for /dev/sdb1 on /mnt/target
2025-06-15 14:25:32 [INFO] safe-mount: write escalation confirmed for /dev/sdb1 (phrase matched)
2025-06-15 14:25:32 [INFO] safe-mount: /dev/sdb1 mounted RW on /mnt/target, timer=1800s
2025-06-15 14:55:32 [INFO] safe-mount: auto-remount-RO timer expired for /dev/sdb1
2025-06-15 14:55:32 [INFO] safe-mount: /dev/sdb1 remounted RO on /mnt/target
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
   codexctl emergency-freeze
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
3. Then create a new persistence partition with `codexctl persistence setup`.

### Immediate shutdown

```bash
# Clean shutdown (waits for operations to complete)
codexctl shutdown

# Emergency shutdown (immediate power-off)
codexctl emergency-shutdown
```
