# CodexOS — Operating Rules

> **CodexOS Lite** is a bootable Alpine Linux appliance whose primary interface
> is OpenAI Codex CLI.  These rules govern how Codex should interact with the
> system.  They are placed in `/workspace/AGENTS.md` on first boot and should
> be consulted before performing any privileged or destructive operation.

---

## 1. Disk Safety

1. **Never write to disks that are not the boot device or the designated
   persistence partition** without explicit user confirmation.
2. **Always run `codex-disk-inventory` first** before touching any block
   device.  This produces a manifest of all attached storage with labels,
   filesystems, and a safety assessment.
3. **Mount foreign / unknown filesystems read-only first** (`codex-mount-ro`).
   Only switch to read-write when the user explicitly requests it and the
   filesystem is known to be safe.
4. The persistence partition is identified by label `codex-persist`.  It may
   be encrypted (LUKS).  Never format or repartition it unless the user
   explicitly asks to reset persistence.

## 2. Persistence Layout

```
/persist/
├── config/          # Configuration files
│   ├── auto-update.conf
│   ├── network.conf
│   └── codex.conf
├── data/            # Persistent data (mounted at /workspace/data)
├── logs/            # Rotated log files
├── backups/         # Workspace backups
└── ssh/             # SSH keys (if configured)
```

## 3. Network Operations

1. Use `codex-network` for all network configuration.  Do not manipulate
   `dhcpcd`, `iwd`, or interface state directly.
2. When on an unfamiliar network, prefer wired (ethernet) over wireless.
3. Log all network changes to `/persist/logs/network.log`.

## 4. Updates & Maintenance

1. Use `codex-update` to update the Codex CLI binary.
2. The system runs on Alpine Linux; `apk upgrade` should only be run when
   the user requests a full system update.
3. Automatic Codex updates run via cron (default: every 6 hours).
   See `/persist/config/auto-update.conf` for schedule control.

## 5. Logging

1. All important operations **must** be logged to `/persist/logs/`.
2. Log format: `YYYY-MM-DD HH:MM:SS [LEVEL] message`
3. Rotate logs: keep last 7 days, compress older entries.

## 6. Security

1. The `codex` user has passwordless `doas` access **only** to the
   whitelisted `codex-*` commands listed in `/etc/doas.conf`.
2. Never attempt to escalate privileges outside these commands.
3. API keys and credentials are stored in `/persist/config/` with
   restrictive permissions (0600, owned by `codex`).

## 7. Workspace

1. `/workspace` is the default working directory for all Codex sessions.
2. Files created in `/workspace` are ephemeral unless stored under the
   bind-mounted `/workspace/data` (backed by `/persist/data/`).
3. Use `codex-backup` to snapshot the workspace to `/persist/backups/`.

## 8. Error Handling

1. If any `codex-*` wrapper command fails, check `/persist/logs/codex.log`
   for details and report the error clearly to the user.
2. Never silently ignore errors from disk or filesystem operations.
3. On I/O errors, immediately remount affected filesystems read-only and
   notify the user.

---

*Last updated: $(date -Iseconds)*
*CodexOS Lite — Alpine Linux + OpenAI Codex CLI*
