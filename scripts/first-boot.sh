#!/usr/bin/env bash
# =============================================================================
# CoLinux Lite — First Boot Initialization Script
# =============================================================================
# Runs on first boot to set up the CoLinux environment:
#   1. Creates runtime directories
#   2. Generates disk inventory
#   3. Sets up encrypted persistence (if new)
#   4. Creates /workspace
#   5. Detects and configures network
#   6. Prompts for Codex authentication (API key or ChatGPT sign-in)
#   7. Copies AGENTS.md to /workspace
#
# This script is designed to run as root during early boot (OpenRC service)
# and is idempotent — safe to re-run without side effects (ROADMAP v0.3
# "First-boot idempotency"). Idempotency is enforced two ways:
#   1. Top-level guard: if $FIRST_BOOT_FLAG exists and --force was not passed,
#      the script logs and exits 0 without re-running any step.
#   2. Per-step guards: every step that touches persistent state (mounts,
#      LUKS, network daemons, auth file, cron) checks current state before
#      acting, so even --force re-runs (or a deleted marker) are safe.
#
# Dry-run / simulation mode:
#   first-boot.sh --dry-run
# Redirects $CODEX_PERSIST to a tmp directory and skips destructive or
# host-disrupting steps (persistence mount, DHCP networking, Codex download,
# interactive auth, cron install). Still runs: runtime dir setup, disk
# inventory, AGENTS.md copy, postinstall hooks, first-boot marker write.
# Use this from smoke-test.sh --first-boot to validate the hook execution
# path without requiring a real boot or root device access.
#
# Force re-init:
#   first-boot.sh --force
# Re-runs every step even if $FIRST_BOOT_FLAG already exists. Per-step guards
# still apply, so this is safe: no duplicate mounts, no clobbered auth file,
# no duplicated cron entries. Use for recovery after a partial first boot.
# =============================================================================
set -euo pipefail

DRY_RUN=false
FORCE=false

# ── Argument parsing (dry-run aware) ─────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|--simulate)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--dry-run] [--force]"
            echo ""
            echo "  --dry-run   Simulate first boot using a tmp directory for /persist."
            echo "              Skips disk mount, network DHCP, Codex download, auth, and cron."
            echo "              Postinstall hooks still execute, and the first-boot marker is written."
            echo "  --force     Re-run even if /persist/.first-boot-done already exists."
            echo "              Per-step guards still apply (no duplicate mounts / cron / auth clobber)."
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ── Configuration ─────────────────────────────────────────────────────────────
CODEX_WORKSPACE="/workspace"
CODEX_PERSIST="/persist"
CODEX_RUNTIME="/run/codex"

# In dry-run mode, redirect persist-derived paths to an isolated tmp area so
# we never touch a real /persist mount or write outside the simulated scope.
if [[ "$DRY_RUN" == true ]]; then
    CODEX_PERSIST="${CODEX_PERSIST_SIM:-/tmp/colinux-firstboot-sim}"
    # CODEX_RUNTIME must also live under the simulated persist tree so that
    # non-root / CI containers (where /run/codex is not writable) can run the
    # dry-run path without spurious permission errors.
    CODEX_RUNTIME="$CODEX_PERSIST/run"
fi

CODEX_CONFIG="$CODEX_PERSIST/config"
CODEX_LOGS="$CODEX_PERSIST/logs"
LOGFILE="$CODEX_LOGS/first-boot.log"
CODEX_DATA="$CODEX_PERSIST/data"
FIRST_BOOT_FLAG="$CODEX_PERSIST/.first-boot-done"

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
    local level="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local msg="[$ts] [$level] $*"

    echo "$msg"
    mkdir -p "$CODEX_LOGS"
    echo "$msg" >> "$CODEX_LOGS/first-boot.log"
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# ── Step 1: Create runtime directories ────────────────────────────────────────
setup_runtime_dirs() {
    log_info "Creating runtime directories..."

    mkdir -p "$CODEX_RUNTIME"
    mkdir -p "$CODEX_WORKSPACE"
    mkdir -p "$CODEX_LOGS"
    mkdir -p "$CODEX_CONFIG"
    mkdir -p "$CODEX_DATA"
    mkdir -p "$CODEX_PERSIST/backups"
    mkdir -p "$CODEX_PERSIST/ssh"

    # Set permissions
    chown -R codex:codex "$CODEX_WORKSPACE" 2>/dev/null || true
    chown -R codex:codex "$CODEX_PERSIST" 2>/dev/null || true
    chmod 700 "$CODEX_PERSIST/ssh" 2>/dev/null || true

    log_info "Runtime directories created."
}

# ── Step 2: Generate disk inventory ──────────────────────────────────────────
generate_disk_inventory() {
    log_info "Generating disk inventory..."

    local inventory_file="$CODEX_RUNTIME/disks.json"

    # In dry-run mode, skip the codex-disk-inventory wrapper because it writes
    # to a hardcoded /persist/logs path that bypasses our simulated persist.
    if [[ "$DRY_RUN" == true ]]; then
        generate_disk_inventory_manual
        log_info "Disk inventory saved to $inventory_file"
        return 0
    fi

    if command -v codex-disk-inventory >/dev/null 2>&1; then
        codex-disk-inventory > "$inventory_file" 2>&1 || {
            log_warn "codex-disk-inventory failed — generating manually"
            generate_disk_inventory_manual
        }
    else
        generate_disk_inventory_manual
    fi

    log_info "Disk inventory saved to $inventory_file"
}

generate_disk_inventory_manual() {
    local inventory_file="$CODEX_RUNTIME/disks.json"

    # Fallback: use lsblk JSON output
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -J -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,MODEL \
            > "$inventory_file" 2>/dev/null || echo '{}' > "$inventory_file"
    elif command -v fdisk >/dev/null 2>&1; then
        echo '{"disks": [], "note": "minimal inventory - fdisk only"}' > "$inventory_file"
    else
        echo '{}' > "$inventory_file"
    fi
}

# ── Step 3: Setup persistence ────────────────────────────────────────────────
setup_persistence() {
    log_info "Checking for persistence partition..."

    # Look for partition labeled "codex-persist"
    local persist_dev=""
    persist_dev="$(blkid -t LABEL=codex-persist -o device 2>/dev/null | head -1)" || true

    if [ -z "$persist_dev" ]; then
        log_info "No persistence partition found. System will run in diskless mode."
        log_info "To enable persistence, create a partition labeled 'codex-persist'."
        return 0
    fi

    log_info "Found persistence device: $persist_dev"

    # Check if it's encrypted (LUKS)
    if cryptsetup isLuks "$persist_dev" 2>/dev/null; then
        log_info "Persistence partition is LUKS-encrypted."

        # Try to open — if no keyfile, prompt on console
        local mapper_name="codex-persist"
        local keyfile="$CODEX_CONFIG/persist.key"

        # Idempotency: if the mapper device already exists (e.g. re-run, or
        # already opened by an initramfs/crypttab), skip the open call.
        # cryptsetup open fails noisily on an already-open device.
        if [ -e "/dev/mapper/$mapper_name" ]; then
            log_info "Encrypted partition already mapped at /dev/mapper/$mapper_name."
        elif [ -f "$keyfile" ]; then
            log_info "Opening encrypted partition with keyfile..."
            cryptsetup open --key-file "$keyfile" "$persist_dev" "$mapper_name" 2>/dev/null || {
                log_warn "Failed to open with keyfile — will prompt on next manual mount."
                return 0
            }
        else
            log_info "No keyfile found. Run 'codex-usb-persist unlock' to decrypt manually."
            return 0
        fi

        persist_dev="/dev/mapper/$mapper_name"
    fi

    # Mount the persistence partition
    local mount_point="$CODEX_PERSIST"
    mkdir -p "$mount_point"

    if ! mountpoint -q "$mount_point"; then
        # Check filesystem and mount
        local fs_type
        fs_type="$(blkid -s TYPE -o value "$persist_dev" 2>/dev/null || echo "")"

        case "$fs_type" in
            ext4|btrfs|xfs)
                mount -t "$fs_type" "$persist_dev" "$mount_point" 2>/dev/null || {
                    log_error "Failed to mount $persist_dev on $mount_point"
                    return 1
                }
                ;;
            "")
                log_warn "No filesystem detected on $persist_dev"
                return 0
                ;;
            *)
                mount "$persist_dev" "$mount_point" 2>/dev/null || {
                    log_error "Failed to mount $persist_dev"
                    return 1
                }
                ;;
        esac

        log_info "Persistence mounted at $mount_point"
    fi

    # Re-run directory setup now that persistence is mounted
    setup_runtime_dirs

    # Bind-mount data into workspace.
    # Idempotency: guard with mountpoint so re-runs don't emit "already mounted"
    # warnings or stack duplicate bind-mounts.
    if [ -d "$CODEX_DATA" ] && ! mountpoint -q "$CODEX_WORKSPACE/data" 2>/dev/null; then
        mkdir -p "$CODEX_WORKSPACE/data"
        mount --bind "$CODEX_DATA" "$CODEX_WORKSPACE/data" 2>/dev/null || true
    fi
}

# ── Step 4: Network detection ────────────────────────────────────────────────
setup_network() {
    log_info "Detecting network interfaces..."

    local has_eth=false
    has_wifi=false

    # List interfaces
    for iface in /sys/class/net/*; do
        local name
        name="$(basename "$iface")"
        [ "$name" = "lo" ] && continue

        if [ -d "$iface/wireless" ]; then
            has_wifi=true
            log_info "  WiFi interface: $name"
        else
            has_eth=true
            log_info "  Ethernet interface: $name"
        fi
    done

    # Start DHCP on ethernet interfaces.
    # Idempotency: skip if a DHCP client is already running or an IPv4 lease
    # is already held on an ethernet interface — re-invoking dhcpcd/udhcpc on
    # every boot can spawn extra daemon instances or produce noisy errors.
    if $has_eth; then
        local dhcp_running=false
        if pgrep -x dhcpcd >/dev/null 2>&1 || pgrep -x udhcpc >/dev/null 2>&1; then
            dhcp_running=true
        fi

        if ! $dhcp_running; then
            log_info "Starting DHCP on ethernet..."
            if command -v dhcpcd >/dev/null 2>&1; then
                dhcpcd -q 2>/dev/null || true
            elif command -v udhcpc >/dev/null 2>&1; then
                local iface_name
                for iface in /sys/class/net/eth* /sys/class/net/en*; do
                    if [ -d "$iface" ]; then
                        iface_name="$(basename "$iface")"
                        # Skip interfaces that already hold an IPv4 address.
                        if ip -4 addr show "$iface_name" 2>/dev/null | grep -q 'inet '; then
                            continue
                        fi
                        udhcpc -i "$iface_name" -q -s /usr/share/udhcpc/default.script 2>/dev/null || true
                    fi
                done
            fi
        else
            log_info "DHCP client already running — skipping DHCP start."
        fi
    elif $has_wifi; then
        log_info "WiFi interface detected; configure credentials manually if ethernet is unavailable."
    fi

    # Check connectivity
    if command -v curl >/dev/null 2>&1; then
        if curl -sf --connect-timeout 5 https://api.github.com >/dev/null 2>&1; then
            log_info "Internet connectivity: OK"
        else
            log_warn "Internet connectivity: NOT AVAILABLE"
            log_warn "Codex CLI requires internet access for API calls."
        fi
    fi
}

# ── Step 5: Codex authentication ─────────────────────────────────────────────
setup_codex_auth() {
    log_info "Setting up Codex authentication..."

    local auth_file="$CODEX_CONFIG/codex.conf"
    local existing_key=""
    local existing_auth=""

    # Safely extract existing authentication values (never source the file)
    if [ -f "$auth_file" ]; then
        existing_key="$(grep -E '^[[:space:]]*(export[[:space:]]+)?OPENAI_API_KEY=' "$auth_file" 2>/dev/null | head -1 \
            | sed -E 's/^[[:space:]]*(export[[:space:]]+)?OPENAI_API_KEY=//' | tr -d '"' || true)"
        existing_auth="$(grep -E '^[[:space:]]*(export[[:space:]]+)?CODEX_AUTH=' "$auth_file" 2>/dev/null | head -1 \
            | sed -E 's/^[[:space:]]*(export[[:space:]]+)?CODEX_AUTH=//' | tr -d '"' || true)"

        # Skip if empty or only contained a masked placeholder
        if [ "$existing_key" = "***" ] || [ "$existing_key" = "MASKED" ] || [ -z "$existing_key" ]; then
            existing_key=""
        fi
        if [ "$existing_auth" = "***" ] || [ "$existing_auth" = "MASKED" ] || [ -z "$existing_auth" ]; then
            existing_auth=""
        fi

        # Check if already configured after rejecting masked placeholders.
        # CODEX_AUTH is managed by Codex itself; OPENAI_API_KEY is preserved below.
        if [ -n "$existing_auth" ]; then
            log_info "Codex authentication already configured."
            return 0
        fi
        # Idempotency: if a real (non-masked) API key is already present in the
        # file, leave the file untouched. The previous implementation rewrote
        # the whole file with only the key, clobbering any other variables
        # (e.g. CODEX_AUTH added later by `codex auth`, or user config). A
        # real key on disk means the file is already in a good state.
        if [ -n "$existing_key" ]; then
            log_info "OPENAI_API_KEY already present in $auth_file — leaving file unchanged."
            return 0
        fi
    fi

    # Non-interactive boot without any existing auth: nothing to do. The
    # interactive prompt below requires a TTY and is only reached on a real
    # first boot, never on a re-run (the top-level marker guard short-circuits
    # those, and per-step guards above catch the rare --force re-run case).
    if [ ! -t 0 ]; then
        log_info "Non-interactive boot — run 'codex auth' to set up authentication."
        return 0
    fi

    # Interactive prompt (only on a real TTY)
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║            CoLinux — Authentication Setup           ║"
    echo "╠═══════════════════════════════════════════════════════╣"
    echo "║                                                       ║"
    echo "║  Codex CLI requires authentication to work.           ║"
    echo "║  Choose one of the following methods:                 ║"
    echo "║                                                       ║"
    echo "║  1. Enter your OpenAI API key                         ║"
    echo "║  2. Sign in with ChatGPT (requires browser)           ║"
    echo "║  3. Skip (configure later via: codex auth)            ║"
    echo "║                                                       ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""

    local choice=""
    local api_key=""
    read -rp "  Choice [1/2/3]: " choice
    case "$choice" in
        1)
            read -rp "  Enter OpenAI API key: " api_key
            if [ -n "$api_key" ]; then
                cat > "$auth_file" <<EOF
# CoLinux authentication configuration
# Created: $(date -Iseconds)
export OPENAI_API_KEY="$api_key"
EOF
                chmod 600 "$auth_file"
                chown codex:codex "$auth_file" 2>/dev/null || true
                log_info "API key saved to $auth_file"
            fi
            ;;
        2)
            log_info "Run 'codex auth' after login to authenticate with ChatGPT."
            ;;
        3)
            log_info "Authentication skipped. Run 'codex auth' later."
            ;;
        *)
            log_warn "Invalid choice. Run 'codex auth' to configure later."
            ;;
    esac
}

# ── Step 6: Copy AGENTS.md ───────────────────────────────────────────────────
setup_agents_md() {
    log_info "Setting up AGENTS.md..."

    local agents_dest="$CODEX_WORKSPACE/AGENTS.md"

    # Check for bundled AGENTS.md (in the image)
    local bundled_agents=""
    for candidate in \
        "/usr/share/colinux/AGENTS.md" \
        "/etc/colinux/AGENTS.md" \
        "/opt/colinux/AGENTS.md"; do
        if [ -f "$candidate" ]; then
            bundled_agents="$candidate"
            break
        fi
    done

    if [ -f "$agents_dest" ]; then
        log_info "AGENTS.md already exists in workspace."
        return 0
    fi

    if [ -n "$bundled_agents" ]; then
        cp "$bundled_agents" "$agents_dest"
        log_info "AGENTS.md copied from $bundled_agents"
    else
        # Generate a basic one
        cat > "$agents_dest" <<'EOF'
# CoLinux — Operating Rules

1. **Disk Safety**: Always run `codex-disk-inventory` before accessing foreign disks.
2. **Read-First**: Mount unknown filesystems read-only before any writes.
3. **Persistence**: The `codex-persist` labeled partition stores all persistent data.
4. **Logging**: Log important operations to `/persist/logs/`.
5. **Security**: Only use whitelisted `codex-*` commands for privileged operations.
6. **Workspace**: Default working directory is `/workspace`.

See the full CoLinux documentation for detailed guidelines.
EOF
        log_info "Basic AGENTS.md generated."
    fi

    chown codex:codex "$agents_dest" 2>/dev/null || true
}

# ── Step 7: Install cron jobs ────────────────────────────────────────────────
setup_cron() {
    log_info "Setting up cron jobs..."

    # Daily log rotation — always installed, independent of the update schedule
    # (ROADMAP v0.3 "Logging standardization"). Runs codex-log-rotate with the
    # standard policy defined in /usr/local/lib/colinux/logging.sh.
    if [ -x /usr/local/bin/codex-log-rotate ]; then
        (crontab -l 2>/dev/null | grep -v 'codex-log-rotate'; echo "0 3 * * * /usr/local/bin/codex-log-rotate --quiet") | crontab - 2>/dev/null || {
            log_warn "Failed to install log-rotation cron job (crond may not be running)"
        }
        log_info "Log-rotation cron job installed (daily at 03:00)."
    fi

    if [ -x /usr/local/bin/cron-codex-update ]; then
        if [ -x /etc/init.d/codex-auto-update ]; then
            log_info "Skipping generic user crontab; codex-auto-update OpenRC service manages the schedule."
            return 0
        fi

        # Install cron job for automatic Codex updates (every 6 hours)
        (crontab -l 2>/dev/null | grep -v 'cron-codex-update'; echo "0 */6 * * * /usr/local/bin/cron-codex-update") | crontab - 2>/dev/null || {
            log_warn "Failed to install cron job (crond may not be running)"
        }
        log_info "Codex auto-update cron job installed (every 6 hours)."
    fi
}

# ── Install Codex CLI if build-time injection did not include it ──────────────
install_codex_if_missing() {
    if command -v codex >/dev/null 2>&1; then
        log_info "Codex CLI already installed."
        return 0
    fi

    if [ ! -x /usr/local/bin/setup-codex ]; then
        log_warn "Codex CLI is missing and /usr/local/bin/setup-codex is not available."
        return 0
    fi

    log_info "Codex CLI missing; running setup-codex fallback..."
    if /usr/local/bin/setup-codex >> "$LOGFILE" 2>&1; then
        log_info "Codex CLI installed by first-boot fallback."
    else
        log_warn "setup-codex fallback failed; cron-codex-update may retry later."
    fi
}

# ── Run packaged postinstall hooks ───────────────────────────────────────────
run_postinstall_hooks() {
    local hook_dir="$CODEX_CONFIG/postinstall"
    local failed=0

    if [ ! -d "$hook_dir" ]; then
        return 0
    fi

    log_info "Running postinstall hooks..."
    while IFS= read -r hook; do
        log_info "Running postinstall hook: $(basename "$hook")"
        if "$hook" >> "$LOGFILE" 2>&1; then
            rm -f "$hook"
            log_info "Postinstall hook completed: $(basename "$hook")"
        else
            failed=1
            log_warn "Postinstall hook failed and will be retried on next first-boot run: $(basename "$hook")"
        fi
    done < <(find "$hook_dir" -maxdepth 1 -type f -perm /111 -print | sort)

    return "$failed"
}

# ── Mark first boot complete ─────────────────────────────────────────────────
mark_complete() {
    mkdir -p "$(dirname "$FIRST_BOOT_FLAG")"
    date -Iseconds > "$FIRST_BOOT_FLAG"
    # chown/chmod are best-effort; they may fail when running as non-root
    # (e.g., inside Docker during --dry-run smoke tests). The flag file is
    # still created, which is what callers check.
    chown root:root "$FIRST_BOOT_FLAG" 2>/dev/null || true
    chmod 644 "$FIRST_BOOT_FLAG" 2>/dev/null || true
    log_info "First boot initialization complete."
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    log_info "=== CoLinux Lite — First Boot Initialization ==="
    log_info "Kernel: $(uname -r)"
    log_info "Arch:   $(uname -m)"
    log_info "Date:   $(date)"

    # Top-level idempotency guard (ROADMAP v0.3 "First-boot idempotency").
    # If first boot was already completed and --force was not passed, exit
    # cleanly without re-running any step. Per-step guards (below) make even
    # --force re-runs safe, but the top-level guard avoids unnecessary work
    # and log noise on every boot when the OpenRC/systemd ConditionPathExists
    # guard is bypassed (e.g. manual invocation for recovery).
    if [[ "$FORCE" != true ]] && [[ -f "$FIRST_BOOT_FLAG" ]]; then
        log_info "First boot already complete ($FIRST_BOOT_FLAG present)."
        log_info "Use --force to re-run initialization steps."
        return 0
    fi

    if [[ "$FORCE" == true ]]; then
        log_info "FORCE MODE — re-running all steps despite $FIRST_BOOT_FLAG."
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "DRY-RUN MODE — using $CODEX_PERSIST"
        log_info "Skipping: persistence mount, network DHCP, Codex download, auth, cron."
    fi

    setup_runtime_dirs
    generate_disk_inventory

    if [[ "$DRY_RUN" != true ]]; then
        setup_persistence
        setup_network
        install_codex_if_missing
        setup_codex_auth
        setup_cron
    else
        log_info "DRY-RUN: skipping setup_persistence (no mount/cryptsetup)."
        log_info "DRY-RUN: skipping setup_network (no DHCP/host disruption)."
        log_info "DRY-RUN: skipping install_codex_if_missing (no network download)."
        log_info "DRY-RUN: skipping setup_codex_auth (no TTY prompt)."
        log_info "DRY-RUN: skipping setup_cron (no host crontab write)."
    fi

    setup_agents_md
    run_postinstall_hooks
    mark_complete

    log_info "=== First boot complete ==="
}

main "$@"
