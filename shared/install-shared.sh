#!/usr/bin/env bash
# ============================================================================
# CodexOS — Shared Infrastructure Installer
# ============================================================================
# Copies shared packages, scripts, and tools to the specified edition overlay
# directory for inclusion during image builds.
#
# Usage:
#   install-shared.sh --edition <edition> --dest <overlay-dir>
#
# Editions: lite | lite-gui | compat | desktop
#
# Installs:
#   - Camoufox browser integration (all editions)
#   - WiFi wizard (all editions)
#   - Network stack (all editions)
#   - Package lists for the target distro (Alpine or Debian)
#   - Systemd/OpenRC init scripts where applicable
#
# The --dest directory is the overlay root where files will be installed
# (e.g., /tmp/build/overlay for Alpine, or /tmp/build/rootfs for Debian).
# ============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EDITION=""
DEST_DIR=""
DISTRO="alpine"  # default; detected or overridden
VERBOSE=0
DRY_RUN=0

# Colors
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()    { echo -e "${GREEN}[install-shared]${NC} $*"; }
warn()   { echo -e "${YELLOW}[install-shared]${NC} WARNING: $*" >&2; }
error()  { echo -e "${RED}[install-shared]${NC} ERROR: $*" >&2; }
die()    { error "$*"; exit 1; }
step()   { echo -e "${BLUE}[install-shared]${NC} → $*"; }
debug()  { [[ "$VERBOSE" == "1" ]] && echo -e "${CYAN}[debug]${NC} $*" || true; }

# Safe copy: creates parent dirs, logs actions
safe_copy() {
    local src="$1"
    local dest="$2"
    local mode="${3:-755}"

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "  [DRY-RUN] copy $src -> $dest (mode=$mode)"
        return
    fi

    if [[ ! -f "$src" ]]; then
        warn "Source not found: $src"
        return 1
    fi

    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    chmod "$mode" "$dest"
    debug "  Copied: $src -> $dest"
}

# Safe install of a directory tree
safe_copy_dir() {
    local src="$1"
    local dest="$2"

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "  [DRY-RUN] copy-dir $src -> $dest"
        return
    fi

    if [[ ! -d "$src" ]]; then
        warn "Source directory not found: $src"
        return 1
    fi

    mkdir -p "$dest"
    cp -r "$src"/* "$dest"/
    debug "  Copied directory: $src -> $dest"
}

# Create a file with content
safe_write() {
    local dest="$1"
    local content="$2"
    local mode="${3:-755}"

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "  [DRY-RUN] write $dest (mode=$mode)"
        return
    fi

    mkdir -p "$(dirname "$dest")"
    cat > "$dest" <<< "$content"
    chmod "$mode" "$dest"
    debug "  Wrote: $dest"
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --edition)
                EDITION="${2:-}"
                shift 2
                ;;
            --dest)
                DEST_DIR="${2:-}"
                shift 2
                ;;
            --distro)
                DISTRO="${2:-}"
                shift 2
                ;;
            --verbose|-v)
                VERBOSE=1
                shift
                ;;
            --dry-run|-n)
                DRY_RUN=1
                shift
                ;;
            -h|--help)
                echo "Usage: $0 --edition <edition> --dest <overlay-dir> [OPTIONS]"
                echo ""
                echo "Required:"
                echo "  --edition ED    Edition: lite|lite-gui|compat|desktop"
                echo "  --dest DIR      Overlay destination directory"
                echo ""
                echo "Optional:"
                echo "  --distro D      Target distro: alpine|debian (default: auto-detect)"
                echo "  --verbose       Verbose output"
                echo "  --dry-run       Show what would be done without executing"
                echo "  -h, --help      Show this help"
                echo ""
                echo "Examples:"
                echo "  $0 --edition lite --dest /tmp/build/overlay"
                echo "  $0 --edition desktop --dest /tmp/build/rootfs --distro debian"
                exit 0
                ;;
            *)
                die "Unknown argument: $1. Use --help for usage."
                ;;
        esac
    done

    # Validate
    [[ -z "$EDITION" ]] && die "--edition is required. Use --help for usage."
    [[ -z "$DEST_DIR" ]] && die "--dest is required. Use --help for usage."

    case "$EDITION" in
        lite|lite-gui|compat|desktop) ;;
        *) die "Invalid edition '$EDITION'. Must be: lite|lite-gui|compat|desktop" ;;
    esac
}

# ---------------------------------------------------------------------------
# Auto-detect distro from destination
# ---------------------------------------------------------------------------
detect_distro() {
    if [[ -f "$DEST_DIR/etc/alpine-release" ]]; then
        echo "alpine"
    elif [[ -f "$DEST_DIR/etc/debian_version" ]] || [[ -f "$DEST_DIR/etc/os-release" ]]; then
        echo "debian"
    else
        echo "$DISTRO"
    fi
}

# Has GUI capability for this edition?
has_gui() {
    case "$EDITION" in
        lite-gui|compat|desktop) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Install package lists
# ---------------------------------------------------------------------------
install_package_lists() {
    step "Installing package lists for $DISTRO..."

    local pkg_dest="$DEST_DIR/persist/config/packages"
    mkdir -p "$pkg_dest" 2>/dev/null || true

    # Network/WiFi packages
    local net_pkg_file="$SCRIPT_DIR/packages/${DISTRO}-network-wifi.txt"
    if [[ -f "$net_pkg_file" ]]; then
        safe_copy "$net_pkg_file" "$pkg_dest/network-wifi.txt" 644
    else
        warn "Package list not found: $net_pkg_file"
    fi

    # Camoufox packages
    local cam_pkg_file="$SCRIPT_DIR/packages/${DISTRO}-camoufox.txt"
    if [[ -f "$cam_pkg_file" ]]; then
        safe_copy "$cam_pkg_file" "$pkg_dest/camoufox.txt" 644
    else
        warn "Package list not found: $cam_pkg_file"
    fi

    # Create a combined "shared" package list for easy installation
    local combined="$pkg_dest/shared-packages.txt"
    {
        echo "# CodexOS Shared Dependencies — $DISTRO — $EDITION edition"
        echo "# Auto-generated by install-shared.sh on $(date -Iseconds)"
        echo ""
        echo "# --- Network & WiFi ---"
        [[ -f "$net_pkg_file" ]] && grep -v '^\s*#' "$net_pkg_file" | grep -v '^\s*$'
        echo ""
        echo "# --- Camoufox Browser ---"
        [[ -f "$cam_pkg_file" ]] && grep -v '^\s*#' "$cam_pkg_file" | grep -v '^\s*$'
    } > "$combined" 2>/dev/null
    debug "  Created combined package list: $combined"

    log "Package lists installed to $pkg_dest"
}

# ---------------------------------------------------------------------------
# Install Camoufox integration
# ---------------------------------------------------------------------------
install_camoufox() {
    step "Installing Camoufox browser integration..."

    local sbin="$DEST_DIR/usr/local/sbin"
    local bin="$DEST_DIR/usr/local/bin"
    local opt="$DEST_DIR/opt/camoufox"
    local lib="$DEST_DIR/usr/local/lib/codexos"

    # Copy install script
    safe_copy "$SCRIPT_DIR/camoufox/install-camoufox.sh" "$sbin/install-camoufox.sh"

    # Create the opt directory structure
    mkdir -p "$opt/venv" 2>/dev/null || true

    # Create wrapper stubs that will be replaced by install-camoufox.sh at runtime
    # but provide useful messages until then
    local edition_var="lite"
    has_gui && edition_var="gui"

    for cmd in camoufox camoufox-headless codex-web-search codex-web-browse; do
        safe_write "$bin/$cmd" "#!/bin/sh
# CodexOS — $cmd wrapper stub
# This will be replaced by install-camoufox.sh during first boot or manual install.
# To install now: install-camoufox.sh --edition $EDITION

if [ -f /opt/camoufox/venv/bin/activate ]; then
    . /opt/camoufox/venv/bin/activate
    exec $cmd \"\\\$@\"
else
    echo \"Camoufox is not yet installed. Run: install-camoufox.sh\" >&2
    echo \"  Edition: $EDITION\" >&2
    exit 1
fi
" 755
    done

    # Copy the full install-camoufox.sh to lib for reference
    mkdir -p "$lib/camoufox" 2>/dev/null || true
    safe_copy "$SCRIPT_DIR/camoufox/install-camoufox.sh" "$lib/camoufox/install-camoufox.sh"

    # Install to overlay's sbin (for use during build)
    mkdir -p "$sbin" 2>/dev/null || true
    safe_copy "$SCRIPT_DIR/camoufox/install-camoufox.sh" "$sbin/install-camoufox.sh"

    # Post-install hook script (called during first-boot)
    local postinstall="$DEST_DIR/persist/config/postinstall/50-install-camoufox.sh"
    mkdir -p "$(dirname "$postinstall")" 2>/dev/null || true
    safe_write "$postinstall" "#!/bin/sh
# CodexOS postinstall — Install Camoufox browser
# This runs during first boot if camoufox is not yet installed.

if [ ! -d /opt/camoufox/venv ]; then
    echo \"[postinstall] Installing Camoufox browser...\"
    CODEX_EDITION=$EDITION /usr/local/sbin/install-camoufox.sh 2>&1 | tee /persist/logs/camoufox-install.log || \\
        echo \"[postinstall] WARNING: Camoufox installation failed — will retry on next boot\"
fi
" 755

    log "Camoufox integration installed (edition=$EDITION, gui=$(has_gui && echo yes || echo no))"
}

# ---------------------------------------------------------------------------
# Install WiFi wizard
# ---------------------------------------------------------------------------
install_wifi_wizard() {
    step "Installing WiFi wizard..."

    local bin="$DEST_DIR/usr/local/bin"
    local sbin="$DEST_DIR/usr/local/sbin"
    local lib="$DEST_DIR/usr/local/lib/codexos"

    # Copy the wizard script
    safe_copy "$SCRIPT_DIR/network/codex-wifi-wizard.sh" "$bin/codex-wifi-wizard.sh"
    safe_copy "$SCRIPT_DIR/network/codex-wifi-wizard.sh" "$sbin/codex-wifi-wizard"

    # Create compatibility symlinks
    safe_write "$bin/wifi-setup" "#!/bin/sh
exec codex-wizard \"\\\$@\"
" 755

    # Create WiFi config directory
    mkdir -p "$DEST_DIR/persist/config/wifi" 2>/dev/null || true

    # Create default WiFi config
    safe_write "$DEST_DIR/persist/config/wifi.conf" "# CodexOS WiFi Configuration
# Managed by codex-wifi-wizard — do not edit manually unless needed

ADAPTER=auto
BACKEND=auto
AUTO_CONNECT=true
KNOWN_NETWORKS=0
" 644

    # Ensure log directory
    mkdir -p "$DEST_DIR/persist/logs" 2>/dev/null || true

    log "WiFi wizard installed"
}

# ---------------------------------------------------------------------------
# Install network stack
# ---------------------------------------------------------------------------
install_network_stack() {
    step "Installing network stack..."

    local bin="$DEST_DIR/usr/local/bin"
    local sbin="$DEST_DIR/usr/local/sbin"
    local lib="$DEST_DIR/usr/local/lib/codexos"

    # Copy the network stack script
    safe_copy "$SCRIPT_DIR/network/codex-network-stack.sh" "$sbin/codex-network-stack"
    safe_copy "$SCRIPT_DIR/network/codex-network-stack.sh" "$bin/codex-network"

    # Create compatibility symlinks
    safe_write "$bin/codex-wifi" "#!/bin/sh
exec codex-wifi-wizard \"\\\$@\"
" 755

    # Create state directory
    mkdir -p "$DEST_DIR/run/codex" 2>/dev/null || true

    # Install init integration
    if [[ "$DISTRO" == "alpine" ]]; then
        # OpenRC init script
        local initd="$DEST_DIR/etc/init.d/codex-network"
        safe_write "$initd" "#!/sbin/openrc-run
# CodexOS Network Init (OpenRC)
# Starts network stack on boot for all editions.

name=\"codex-network\"
description=\"CodexOS unified network initialization\"
command=\"/usr/local/sbin/codex-network-stack\"
command_background=true
pidfile=\"/run/codex-network.pid\"

depend() {
    need localmount
    after bootmisc
    want dbus
}

start_pre() {
    checkpath --directory --owner root:root /run/codex
    checkpath --directory --owner root:root /persist/logs
}
" 755

        # Create runlevel symlink
        mkdir -p "$DEST_DIR/etc/runlevels/boot" 2>/dev/null || true
        ln -sf /etc/init.d/codex-network "$DEST_DIR/etc/runlevels/boot/codex-network" 2>/dev/null || true
        debug "  Created OpenRC init script"

    elif [[ "$DISTRO" == "debian" ]]; then
        # systemd service
        local service="$DEST_DIR/etc/systemd/system/codex-network.service"
        safe_write "$service" "[Unit]
Description=CodexOS Unified Network Initialization
After=network.target network-online.target
Wants=network-online.target
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/codex-network-stack --non-interactive
RemainAfterExit=yes
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
Alias=codex-network.service
" 644

        # Create enable symlink
        mkdir -p "$DEST_DIR/etc/systemd/system/multi-user.target.wants" 2>/dev/null || true
        ln -sf /etc/systemd/system/codex-network.service \
            "$DEST_DIR/etc/systemd/system/multi-user.target.wants/codex-network.service" 2>/dev/null || true
        debug "  Created systemd service"
    fi

    log "Network stack installed (distro=$DISTRO)"
}

# ---------------------------------------------------------------------------
# Install doas/sudo rules
# ---------------------------------------------------------------------------
install_privilege_rules() {
    step "Installing privilege escalation rules..."

    if [[ -f "$DEST_DIR/etc/doas.conf" ]]; then
        # Append codex-* rules to existing doas.conf
        local rules="
# CodexOS — codex-* command whitelist
permit nopass :codex as root cmd /usr/local/bin/codex-wifi-wizard
permit nopass :codex as root cmd /usr/local/sbin/codex-network-stack
permit nopass :codex as root cmd /usr/local/sbin/install-camoufox
"
        echo "$rules" >> "$DEST_DIR/etc/doas.conf"
        debug "  Appended to doas.conf"
    fi

    if [[ -d "$DEST_DIR/etc/sudoers.d" ]]; then
        safe_write "$DEST_DIR/etc/sudoers.d/codex-network" "# CodexOS — codex-* command whitelist for sudo
codex ALL=(root) NOPASSWD: /usr/local/bin/codex-wifi-wizard
codex ALL=(root) NOPASSWD: /usr/local/sbin/codex-network-stack
codex ALL=(root) NOPASSWD: /usr/local/sbin/install-camoufox
" 440
        debug "  Created sudoers.d/codex-network"
    fi
}

# ---------------------------------------------------------------------------
# Create directory skeleton
# ---------------------------------------------------------------------------
create_skeleton() {
    step "Creating directory skeleton..."

    local dirs=(
        "persist/config/wifi"
        "persist/config/packages"
        "persist/config/postinstall"
        "persist/logs"
        "persist/data"
        "persist/backups"
        "persist/ssh"
        "run/codex"
        "opt/camoufox"
        "usr/local/bin"
        "usr/local/sbin"
        "usr/local/lib/codexos"
        "var/lib/iwd"
    )

    for d in "${dirs[@]}"; do
        mkdir -p "$DEST_DIR/$d" 2>/dev/null || true
        debug "  Created: $DEST_DIR/$d"
    done

    # Set permissions on sensitive dirs
    chmod 700 "$DEST_DIR/persist/ssh" 2>/dev/null || true
    chmod 700 "$DEST_DIR/var/lib/iwd" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
    echo ""
    echo -e "${BOLD}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  CodexOS Shared Infrastructure — Summary    ║${NC}"
    echo -e "${BOLD}╚════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Edition:        ${CYAN}$EDITION${NC}"
    echo "  Distro:         ${CYAN}$DISTRO${NC}"
    echo "  Destination:    ${CYAN}$DEST_DIR${NC}"
    echo "  GUI capable:    ${CYAN}$(has_gui && echo 'yes' || echo 'no')${NC}"
    echo ""
    echo "  Installed components:"
    echo -e "    ${GREEN}✓${NC} Camoufox browser integration"
    echo -e "    ${GREEN}✓${NC} WiFi wizard (TTY + GUI)"
    echo -e "    ${GREEN}✓${NC} Unified network stack"
    echo -e "    ${GREEN}✓${NC} Package lists ($DISTRO)"
    echo -e "    ${GREEN}✓${NC} Init integration ($DISTRO)"
    echo -e "    ${GREEN}✓${NC} Privilege rules (doas/sudo)"
    echo ""

    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "  ${YELLOW}DRY RUN — no files were actually modified${NC}"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    # Auto-detect distro if not specified
    if [[ "$DISTRO" == "alpine" ]]; then
        local detected
        detected="$(detect_distro)"
        if [[ -n "$detected" ]]; then
            DISTRO="$detected"
        fi
    fi

    log "CodexOS Shared Infrastructure Installer"
    log "  Edition: $EDITION"
    log "  Distro:  $DISTRO"
    log "  Dest:    $DEST_DIR"
    echo ""

    # Validate destination
    if [[ "$DRY_RUN" == "0" ]]; then
        mkdir -p "$DEST_DIR" || die "Cannot create destination directory: $DEST_DIR"
    fi

    # Execute all installation steps
    create_skeleton
    install_package_lists
    install_camoufox
    install_wifi_wizard
    install_network_stack
    install_privilege_rules

    print_summary

    log "Installation complete!"
}

main "$@"
