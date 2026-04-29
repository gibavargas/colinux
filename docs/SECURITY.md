# Security

This document describes the security architecture, threat model, and guarantees of CodexOS Lite.

## Table of Contents

- [Threat Model](#threat-model)
- [Disk Safety Guarantees](#disk-safety-guarantees)
- [Privilege Model](#privilege-model)
- [Encryption](#encryption)
- [Write Escalation Flow](#write-escalation-flow)
- [Forensic Mode Guarantees](#forensic-mode-guarantees)
- [Reporting Vulnerabilities](#reporting-vulnerabilities)
- [Signed Releases Plan](#signed-releases-plan)

---

## Threat Model

### What CodexOS Lite protects against

| Threat | Protection |
|---|---|
| **Accidental data destruction** by AI or user | Multi-step write escalation with typed safety phrase |
| **Unauthorized writes** to attached disks | Read-only-first mount policy; explicit write confirmation |
| **Data at rest exposure** on USB drive | LUKS2 encryption (AES-256-XTS) for persistence partition |
| **Boot device tampering** | Boot device is immutable from within the running system |
| **Privilege escalation** beyond Codex wrappers | doas whitelist; Codex user has no raw root access |
| **Silent operations** on disks | All disk operations are logged with timestamps and SHA-256 verification |
| **Compromised Codex CLI version** | Auto-update from verified channels; optional pinned versions |

### What CodexOS Lite does NOT protect against

| Threat | Notes |
|---|---|
| **Physical access attacks** (evil maid) | Firmware-level attacks are out of scope. UEFI Secure Boot is not enforced. |
| **Kernel-level exploits** | If the kernel is compromised, all guarantees are void. |
| **Malicious USB devices** | BadUSB attacks can inject keystrokes. Exercise caution with unknown USB peripherals. |
| **Network-based attacks** | The appliance connects to the OpenAI API. API key theft is possible on compromised networks. Use HTTPS. |
| **Side-channel attacks** | No mitigation for timing attacks, EM emanations, etc. |

---

## Disk Safety Guarantees

CodexOS Lite provides the following *safety invariants*:

1. **No disk is ever written to without explicit human confirmation.** This is enforced at the `safe-mount` and `safe-write` wrapper level, not just by convention.

2. **The boot device cannot be modified from within the running system.** The boot device is excluded from all disk inventory and write operations.

3. **All write operations are logged** with timestamp, target device, operation type, and (where applicable) SHA-256 checksums before and after.

4. **A typed safety phrase is required** for destructive operations (formatting, partitioning, block-level writes). This prevents AI-initiated destructive actions without human intent.

5. **Forensic mode blocks all writes** at the kernel level using block device freeze.

See [`DISK_SAFETY.md`](DISK_SAFETY.md) for the full specification.

---

## Privilege Model

### User accounts

| User | Purpose | Privileges |
|---|---|---|
| `root` | System maintenance | Full access; no direct login |
| `codex` | Codex CLI sessions | passwordless `doas` to whitelisted commands only |

### doas configuration

The `codex` user's `doas.conf` restricts privilege escalation to a strict whitelist:

```
# /etc/doas.conf
# CodexOS Lite — doas rules for the codex user

# Allow codex to run disk safety wrappers
permit nopass codex as root cmd /usr/local/bin/safe-mount
permit nopass codex as root cmd /usr/local/bin/safe-write
permit nopass codex as root cmd /usr/local/bin/disk-inventory

# Allow codex to manage persistence
permit nopass codex as root cmd /usr/local/bin/codex-persistence

# Allow codex to run system info commands
permit nopass codex as root cmd /usr/bin/lsblk
permit nopass codex as root cmd /usr/bin/blkid
permit nopass codex as root cmd /usr/bin/hwinfo

# Allow codex to manage services
permit nopass codex as root cmd /usr/bin/rc-service
permit nopass codex as root cmd /usr/bin/rc-update

# Deny everything else
deny codex
```

### Key principles

- **No raw shell as root.** The `codex` user cannot obtain a root shell via `doas -s`.
- **No arbitrary command execution.** Only whitelisted binary paths are permitted.
- **Each wrapper validates its own arguments** and rejects obviously malicious input (e.g., paths containing `..`, null bytes).
- **The doas.conf is immutable** — it resides on the read-only squashfs root and cannot be modified at runtime.

---

## Encryption

### Persistence partition

The persistence partition uses **LUKS2** with the following parameters:

```
Cipher:        aes-xts-plain64
Key size:      512 bits (256-bit XTS)
Hash:          sha512
PBKDF:         argon2id
Time cost:     4
Memory:        262144 KiB
Parallelism:   4
```

### Key management

- A single user-chosen passphrase protects the persistence partition.
- There is no key escrow or recovery mechanism. **Lost passphrases mean lost data.**
- The passphrase is never stored in plaintext on any device.
- The LUKS header includes an anti-forensic offset (8 MiB) to reduce metadata exposure.

### API key storage

- OpenAI API keys are stored at `/persist/config/codex.conf` with mode `0600`, owned by `codex:codex`.
- Keys are never written to logs, temporary files, or swap.

---

## Write Escalation Flow

When a write operation is requested (either by the user or by Codex CLI), the following sequence occurs:

```
1. safe-mount --write /dev/sdX1 /mnt/target
   │
2. └─► Check: Is /dev/sdX the boot device?
       │    YES → DENY (hardcoded, cannot override)
       │    NO  → continue
       │
3. └─► Check: Is forensic mode active?
       │    YES → DENY
       │    NO  → continue
       │
4. └─► Prompt: "Mount /dev/sdX1 read-write on /mnt/target? [y/N]"
       │    NO  → abort
       │    YES → continue
       │
5. └─► Prompt: "Type the safety phrase shown below to confirm:"
       │    (Display a random 3-word phrase from the safety phrase bank)
       │    MISMATCH → abort
       │    MATCH    → continue
       │
6. └─► Log: timestamp, device, operation, user, confirmation method
       │
7. └─► Execute: mount -o rw /dev/sdX1 /mnt/target
       │
8. └─► Set a 30-minute auto-remount-read-only timer
```

For destructive operations (format, partition, dd):

- Steps 1–5 are the same.
- Step 5 requires a **longer safety phrase** (5 words).
- A **10-second countdown** with a final "ARE YOU SURE?" prompt is added before execution.
- A SHA-256 checksum of the target device's first 1 MiB is recorded *before* the operation.

---

## Forensic Mode Guarantees

When forensic mode is activated (`codexctl forensic on`):

1. **All block devices are frozen** via `blockdev --setro`.
2. **No mount operation with write access** is possible, even with root privileges.
3. **All device nodes under `/dev/`** for block devices are chmod'd to `0444`.
4. **The freeze is enforced at runtime** — a watchdog script checks every 60 seconds that all devices remain read-only.
5. **Imaging operations** (e.g., `codexctl image`) are still available for creating bit-perfect copies with SHA-256 verification.
6. **Forensic mode persists** across sessions until explicitly disabled with `codexctl forensic off`.

---

## Reporting Vulnerabilities

If you discover a security vulnerability in CodexOS Lite, please report it responsibly:

1. **Email**: security@colinux.dev (PGP key available on request)
2. **GitHub**: Open a **draft** security advisory (recommended for code-level issues)
3. **Do not** publicly disclose the vulnerability until a fix is available.

We will acknowledge your report within 48 hours and aim to provide a fix or mitigation within 14 days, depending on severity.

### Severity classification

| Severity | Response time | Scope |
|---|---|---|
| **Critical** (safety bypass) | 48 hours | Disk safety or privilege escalation bypass |
| **High** (data exposure) | 7 days | Encryption failure, key leakage |
| **Medium** (integrity) | 14 days | Logging bypass, tampering |
| **Low** (informational) | 30 days | Best practice violations |

---

## Signed Releases Plan

CodexOS Lite plans to implement release signing in a future version:

- **ISO images** will be signed with an Ed25519 key.
- **Verification** will be available via `sha256sum` + `.sig` files and an `openssl` one-liner.
- **The public signing key** will be published in this repository and on the CoLinux website.
- **Reproducible builds** are a long-term goal to allow independent verification of binary images.

Current status: ✅ SHA-256 checksums provided | 📋 GPG/Ed25519 signatures planned for v1.1
