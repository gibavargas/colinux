#!/usr/bin/env bash
# =============================================================================
# CodexOS Lite — First Boot Initialization Script
# =============================================================================
# Runs on first boot to set up the CodexOS environment:
#   1. Creates runtime directories
#   2. Generates disk inventory
#   3. Sets up encrypted persistence (if new)
#   4. Creates /workspace
#   5. Detects and configures network
#   6. Prompts for Codex authentication (API key or ChatGPT sign-in)
#   7. Copies AGENTS.md to /workspace
#
# This script is designed to run as root during early boot (OpenRC service)
# and should be idempotent — safe to run on every boot.
# =============================================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
CODEX_HOME="/home/codex"
CODEX_WORKSPACE="/workspace"
CODEX_PERSIST="/persist"
CODEX_RUNTIME="/run/codex"
CODEX_CONFIG="$CODEX_PERSIST/config"
CODEX_LOGS="$CODEX_PERSIST/logs"
CODEX_DATA="$CODEX_PERSIST/data"
FIRST_BOOT_FLAG="$CODEX_PERSIST/.first-boot-complete"
MOTD_FILE="/etc/motd"

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

    local inventory_file="$CODEX_RUNTIME/disk-inventory.json"

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
    local inventory_file="$CODEX_RUNTIME/disk-inventory.json"

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
        log_info "Opening encrypted partition..."

        # Try to open — if no keyfile, prompt on console
        local mapper_name="codex_persist"
        local keyfile="$CODEX_CONFIG/persist.key"

        if [ -f "$keyfile" ]; then
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

    # Bind-mount data into workspace
    if [ -d "$CODEX_DATA" ]; then
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

    # Start DHCP on ethernet interfaces
    if $has_eth; then
        log_info "Starting DHCP on ethernet..."
        if command -v dhcpcd >/dev/null 2>&1; then
            dhcpcd -q 2>/dev/null || true
        elif command -v udhcpc >/dev/null 2>&1; then
            for iface in /sys/class/net/eth* /sys/class/net/en*; do
                [ -d "$iface" ] && udhcpc -i "$(basename "$iface")" -q -s /usr/share/udhcpc/default.script 2>/dev/null || true
            done
        fi
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

    # Check if already configured
    if [ -f "$auth_file" ] && grep -q "OPENAI_API_KEY\|CODEX_AUTH" "$auth_file" 2>/dev/null; then
        log_info "Codex authentication already configured."
        return 0
    fi

    # Source any existing environment
    [ -f "$auth_file" ] && . "$auth_file" 2>/dev/null || true

    if [ -n "${OPENAI_API_KEY:-}" ]; then
        log_info "OPENAI_API_KEY found in environment."
        cat > "$auth_file" <<EOF
# CodexOS authentication configuration
# Created: $(date -Iseconds)
export OPENAI_API_KEY="${OPENAI_API_KEY}"
EOF
        chmod 600 "$auth_file"
        chown codex:codex "$auth_file" 2>/dev/null || true
        return 0
    fi

    # Interactive prompt (only on TTY)
    if [ -t 0 ]; then
        echo ""
        echo "╔═══════════════════════════════════════════════════════╗"
        echo "║            CodexOS — Authentication Setup           ║"
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

        read -rp "  Choice [1/2/3]: " choice
        case "$choice" in
            1)
                read -rp "  Enter OpenAI API key: " api_key
                if [ -n "$api_key" ]; then
                    cat > "$auth_file" <<EOF
# CodexOS authentication configuration
# Created: $(date -Iseconds)
export OPENAI_API_KEY="${api_key}"
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
    else
        log_info "Non-interactive boot — run 'codex auth' to set up authentication."
    fi
}

# ── Step 6: Copy AGENTS.md ───────────────────────────────────────────────────
setup_agents_md() {
    log_info "Setting up AGENTS.md..."

    local agents_dest="$CODEX_WORKSPACE/AGENTS.md"

    # Check for bundled AGENTS.md (in the image)
    local bundled_agents=""
    for candidate in \
        "/usr/share/codexos/AGENTS.md" \
        "/etc/codexos/AGENTS.md" \
        "/opt/codexos/AGENTS.md"; do
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
# CodexOS — Operating Rules

1. **Disk Safety**: Always run `codex-disk-inventory` before accessing foreign disks.
2. **Read-First**: Mount unknown filesystems read-only before any writes.
3. **Persistence**: The `codex-persist` labeled partition stores all persistent data.
4. **Logging**: Log important operations to `/persist/logs/`.
5. **Security**: Only use whitelisted `codex-*` commands for privileged operations.
6. **Workspace**: Default working directory is `/workspace`.

See the full CodexOS documentation for detailed guidelines.
EOF
        log_info "Basic AGENTS.md generated."
    fi

    chown codex:codex "$agents_dest" 2>/dev/null || true
}

# ── Step 7: Install cron jobs ────────────────────────────────────────────────
setup_cron() {
    log_info "Setting up cron jobs..."

    if [ -x /usr/local/bin/cron-codex-update ]; then
        # Install cron job for automatic Codex updates (every 6 hours)
        (crontab -l 2>/dev/null | grep -v 'cron-codex-update'; echo "0 */6 * * * /usr/local/bin/cron-codex-update") | crontab - 2>/dev/null || {
            log_warn "Failed to install cron job (crond may not be running)"
        }
        log_info "Codex auto-update cron job installed (every 6 hours)."
    fi
}

# ── Mark first boot complete ─────────────────────────────────────────────────
mark_complete() {
    date -Iseconds > "$FIRST_BOOT_FLAG"
    log_info "First boot initialization complete."
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    log_info "=== CodexOS Lite — First Boot Initialization ==="
    log_info "Kernel: $(uname -r)"
    log_info "Arch:   $(uname -m)"
    log_info "Date:   $(date)"

    setup_runtime_dirs
    generate_disk_inventory
    setup_persistence
    setup_network
    setup_codex_auth
    setup_agents_md
    setup_cron
    mark_complete

    log_info "=== First boot complete ==="
}

main "$@"
