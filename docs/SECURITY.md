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
| **Boot device tampering** | Write wrappers refuse boot-device targets and persistence is separated from the read-only system image |
| **Privilege escalation** beyond Codex wrappers | doas whitelist; Codex user has no raw root access |
| **Silent operations** on disks | Privileged disk wrappers log actions to encrypted persistence |
| **Compromised Codex CLI version** | Auto-install is disabled by default; updates use exact release assets with SHA-256 digest verification |

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

1. **No foreign disk is ever written to without explicit human confirmation.** This is enforced in the privileged `codex-mount-rw`, installer, and persistence wrappers, not just by convention.

2. **The boot device cannot be write-mounted or targeted by shipping installers from within the running system.** Inventory still shows the boot device so the operator can identify it.

3. **Privileged write operations are logged** with timestamp, target device, operation type, and target identifiers.

4. **A typed safety phrase is required** for destructive operations (formatting, partitioning, block-level writes). This prevents AI-initiated destructive actions without human intent.

5. **Forensic mode blocks normal write access** by setting non-boot block devices read-only at runtime and making `codex-mount-rw` refuse write mounts while the forensic lock is present.

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

# Allow codex to run narrow CodexOS wrappers only.
permit nopass codex as root cmd /usr/local/bin/codex-disk-inventory
permit nopass codex as root cmd /usr/local/bin/codex-mount-ro
permit nopass codex as root cmd /usr/local/bin/codex-mount-rw
permit nopass codex as root cmd /usr/local/bin/codex-usb-persist
permit nopass codex as root cmd /usr/local/bin/codex-install-usb
permit nopass codex as root cmd /usr/local/bin/codex-install-pc
permit nopass codex as root cmd /usr/local/bin/codex-network
permit nopass codex as root cmd /usr/local/bin/codex-update
permit nopass codex as root cmd /usr/local/bin/codex-forensic
permit nopass codex as root cmd /usr/local/bin/codex-logs

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
1. codex-mount-rw --confirm SERIAL /dev/sdX1
   │
2. └─► Check: Is /dev/sdX the boot device?
       │    YES → DENY (hardcoded, cannot override)
       │    NO  → continue
       │
3. └─► Check: Is forensic mode active?
       │    YES → DENY
       │    NO  → continue
       │
4. └─► Prompt on /dev/tty: "Type this exact phrase to continue:"
       │    (Display operation-specific phrase with random nonce)
       │    MISMATCH → abort
       │    MATCH    → continue
       │
5. └─► Log: timestamp, device, operation, confirmation method
       │
6. └─► Execute: mount -o rw /dev/sdX1 /mnt/disks/by-device/sdX1
       │
7. └─► Set a 30-minute auto-remount-read-only timer
```

For destructive installer and persistence operations:

- The wrapper displays device path, model, serial, and size.
- The operator must type the target path exactly.
- The operator must type the generated operation-specific phrase.
- Shipping wrappers do not expose a noninteractive confirmation bypass.

---

## Forensic Mode Guarantees

When forensic mode is activated (`codexctl forensic on`):

1. **Non-boot block devices are set read-only** via `blockdev --setro`.
2. **The CodexOS read-write mount wrapper refuses escalation** while the forensic lock is present.
3. **Disabling forensic mode requires an interactive generated phrase** on `/dev/tty`.
4. **The forensic lock persists** in `/persist/state/forensic.lock` when persistence is available.
5. **Read-only collection operations** remain available through `codex-mount-ro` and normal user-space copy tools after mounting evidence read-only.
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
