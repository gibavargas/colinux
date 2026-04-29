#!/usr/bin/env bash
# ============================================================================
# CodexOS — Unified Network Stack
# ============================================================================
# Common network initialization for ALL CodexOS editions.
# Handles Ethernet, WiFi, DNS, connectivity validation, and state reporting.
#
# Usage:
#   codex-network-stack              — Full initialization
#   codex-network-stack --eth-only   — Only configure Ethernet
#   codex-network-stack --wifi-only  — Only configure WiFi
#   codex-network-stack --status     — Show current status
#   codex-network-stack --dns        — Only configure DNS
#
# State: /run/codex/network.json
# Logs:  /persist/logs/network.log
# DNS:   /etc/resolv.conf (Cloudflare 1.1.1.1 primary, Google 8.8.8.8 fallback)
# ============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CODEX_STATE_DIR="/run/codex"
CODEX_NETWORK_JSON="$CODEX_STATE_DIR/network.json"
CODEX_LOG="/persist/logs/network.log"
CODEX_WIFI_WIZARD="/usr/local/bin/codex-wifi-wizard"

DNS_PRIMARY="1.1.1.1"
DNS_SECONDARY="8.8.8.8"
DNS_TERTIARY="9.9.9.9"

CONNECTIVITY_HOST="1.1.1.1"
CONNECTIVITY_TIMEOUT=5

MODE="full"   # full|eth-only|wifi-only|status|dns

# Colors
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_msg() {
    local level="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local msg="[$ts] [$level] [network-stack] $*"
    echo "$msg" >> "$CODEX_LOG" 2>/dev/null || true
}

log_info()  { log_msg "INFO"  "$*"; }
log_warn()  { log_msg "WARN"  "$*"; }
log_error() { log_msg "ERROR" "$*"; }

info()  { echo -e "${GREEN}[network]${NC} $*"; log_info "$*"; }
warn()  { echo -e "${YELLOW}[network]${NC} $*" >&2; log_warn "$*"; }
error() { echo -e "${RED}[network]${NC} $*" >&2; log_error "$*"; }
step()  { echo -e "${BLUE}[network]${NC} → $*"; }

# ---------------------------------------------------------------------------
# Ensure directories
# ---------------------------------------------------------------------------
ensure_dirs() {
    mkdir -p "$CODEX_STATE_DIR" 2>/dev/null || true
    mkdir -p "$(dirname "$CODEX_LOG")" 2>/dev/null || true
    mkdir -p /run/wpa_supplicant 2>/dev/null || true
    mkdir -p /persist/config/wifi 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# State management
# ---------------------------------------------------------------------------
write_state() {
    local mode="$1"
    local iface="${2:-none}"
    local ssid="${3:-}"
    local ip=""
    ip="$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[0-9./]+')" || true
    local dns_ok="false"
    if host google.com &>/dev/null || nslookup google.com &>/dev/null; then
        dns_ok="true"
    fi
    local gateway=""
    gateway="$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')" || true

    mkdir -p "$CODEX_STATE_DIR"
    cat > "$CODEX_NETWORK_JSON" <<EOF
{
    "mode": "$mode",
    "interface": "$iface",
    "ssid": "$ssid",
    "ip": "${ip:-none}",
    "gateway": "${gateway:-none}",
    "dns_primary": "$DNS_PRIMARY",
    "dns_secondary": "$DNS_SECONDARY",
    "dns_working": "$dns_ok",
    "timestamp": "$(date -Iseconds)"
}
EOF
    log_info "State updated: mode=$mode iface=$iface ip=${ip:-none}"
}

# ---------------------------------------------------------------------------
# DNS Configuration
# ---------------------------------------------------------------------------
configure_dns() {
    step "Configuring DNS (Cloudflare $DNS_PRIMARY + Google $DNS_SECONDARY)..."

    # Check if resolv.conf is managed by systemd-resolved or similar
    local managed=false
    if [[ -L /etc/resolv.conf ]]; then
        managed=true
        warn "/etc/resolv.conf is a symlink — DNS may be managed by system service"
    fi

    if [[ "$managed" == "false" ]]; then
        # Write our own resolv.conf
        cat > /etc/resolv.conf <<EOF
# CodexOS DNS Configuration
# Managed by codex-network-stack — do not edit manually
# Primary: Cloudflare ($DNS_PRIMARY)
# Secondary: Google ($DNS_SECONDARY)
nameserver $DNS_PRIMARY
nameserver $DNS_SECONDARY
nameserver $DNS_TERTIARY
EOF
        log_info "DNS configured: $DNS_PRIMARY, $DNS_SECONDARY, $DNS_TERTIARY"
    fi

    # Also ensure nsswitch.conf has proper lookup order
    if [[ -f /etc/nsswitch.conf ]]; then
        if ! grep -q '^hosts:.*dns' /etc/nsswitch.conf; then
            sed -i 's/^hosts:.*/hosts: files dns myhostname/' /etc/nsswitch.conf 2>/dev/null || true
        fi
    fi
}

# ---------------------------------------------------------------------------
# Connectivity test
# ---------------------------------------------------------------------------
test_connectivity() {
    local host="${1:-$CONNECTIVITY_HOST}"
    local timeout="${2:-$CONNECTIVITY_TIMEOUT}"

    step "Testing connectivity ($host)..."

    if ping -c 1 -W "$timeout" "$host" &>/dev/null; then
        info "Network connectivity OK (ping $host)"
        log_info "Connectivity test passed: $host"
        return 0
    fi

    # Try alternative
    if ping -c 1 -W "$timeout" 8.8.8.8 &>/dev/null; then
        info "Network connectivity OK (ping 8.8.8.8)"
        log_info "Connectivity test passed: 8.8.8.8"
        return 0
    fi

    # Try DNS resolution test
    if host -W "$timeout" google.com &>/dev/null 2>&1; then
        info "Network connectivity OK (DNS resolution)"
        log_info "Connectivity test passed: DNS resolution"
        return 0
    fi

    warn "Connectivity test FAILED"
    log_warn "Connectivity test failed for $host and 8.8.8.8"
    return 1
}

# ---------------------------------------------------------------------------
# Ethernet detection and configuration
# ---------------------------------------------------------------------------
detect_ethernet() {
    local eth_iface=""
    for iface in /sys/class/net/eth* /sys/class/net/en*; do
        [[ -e "$iface" ]] || continue
        local name="${iface##*/}"
        # Skip if it's a wireless interface
        [[ -d "$iface/wireless" ]] && continue
        # Check if carrier is detected (cable plugged in)
        local carrier
        carrier="$(cat "$iface/carrier" 2>/dev/null || echo "0")"
        if [[ "$carrier" == "1" ]]; then
            eth_iface="$name"
            break
        fi
        # If carrier is unknown, still consider it (may need time)
        if [[ "$carrier" == "0" ]] && [[ -z "$eth_iface" ]]; then
            eth_iface="$name"
        fi
    done
    echo "$eth_iface"
}

configure_ethernet() {
    local eth_iface="$1"

    step "Configuring Ethernet ($eth_iface)..."

    # Unblock and bring up
    if command -v ip &>/dev/null; then
        ip link set "$eth_iface" up 2>/dev/null || true
    elif command -v ifconfig &>/dev/null; then
        ifconfig "$eth_iface" up 2>/dev/null || true
    fi

    # Get DHCP
    local got_ip=false
    if command -v dhcpcd &>/dev/null; then
        dhcpcd -n "$eth_iface" 2>/dev/null || \
        dhcpcd "$eth_iface" 2>/dev/null || true
        sleep 2
        if ip -4 addr show "$eth_iface" | grep -q 'inet '; then
            got_ip=true
        fi
    fi

    if [[ "$got_ip" == "false" ]]; then
        if command -v udhcpc &>/dev/null; then
            udhcpc -i "$eth_iface" -f -n -q -t 10 2>/dev/null
            sleep 2
            if ip -4 addr show "$eth_iface" | grep -q 'inet ' || \
               ifconfig "$eth_iface" 2>/dev/null | grep -q 'inet '; then
                got_ip=true
            fi
        fi
    fi

    if [[ "$got_ip" == "false" ]]; then
        if command -v dhclient &>/dev/null; then
            dhclient -nw "$eth_iface" 2>/dev/null
            sleep 2
        fi
    fi

    # Verify
    local ip_addr
    ip_addr="$(ip -4 addr show "$eth_iface" 2>/dev/null | grep -oP 'inet \K[0-9.]+')" || true

    if [[ -n "$ip_addr" ]]; then
        info "Ethernet connected: $eth_iface ($ip_addr)"
        log_info "Ethernet configured: $eth_iface IP=$ip_addr"
        write_state "ethernet" "$eth_iface" ""
        return 0
    else
        warn "Ethernet $eth_iface up but no IP address obtained"
        log_warn "Ethernet $eth_iface has no IP"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# WiFi setup
# ---------------------------------------------------------------------------
has_wifi_adapter() {
    for iface in /sys/class/net/wlan* /sys/class/net/wlp*; do
        [[ -e "$iface" ]] || continue
        return 0
    done
    # Also check ip link
    if ip link show 2>/dev/null | grep -qE 'wl'; then
        return 0
    fi
    return 1
}

setup_wifi() {
    step "Setting up WiFi..."

    if ! has_wifi_adapter; then
        warn "No WiFi adapter detected"
        log_warn "No WiFi adapter found"
        write_state "none" "none" ""
        return 1
    fi

    # Try auto-reconnect first if there are known networks
    if [[ -x "$CODEX_WIFI_WIZARD" ]]; then
        if "$CODEX_WIFI_WIZARD" --auto 2>&1; then
            info "WiFi auto-reconnect succeeded"
            return 0
        fi
    fi

    # Check if there's a saved WiFi config we can use
    local wifi_conf="/persist/config/wifi.conf"
    if [[ -f "$wifi_conf" ]]; then
        local auto_connect
        auto_connect="$(grep 'AUTO_CONNECT=' "$wifi_conf" 2>/dev/null | cut -d= -f2)"
        if [[ "$auto_connect" != "true" ]]; then
            log_info "Auto-connect disabled in config"
        fi
    fi

    # If interactive mode (TTY with user), launch wizard
    if [[ -t 0 ]] && [[ "${CODEX_NONINTERACTIVE:-0}" != "1" ]]; then
        warn "No Ethernet connection. Launching WiFi wizard..."
        if [[ -x "$CODEX_WIFI_WIZARD" ]]; then
            "$CODEX_WIFI_WIZARD"
            return $?
        else
            error "WiFi wizard not found at $CODEX_WIFI_WIZARD"
            return 1
        fi
    else
        warn "Non-interactive mode: WiFi requires manual configuration"
        log_warn "Non-interactive: skipping WiFi wizard"
        write_state "none" "none" ""
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Show status
# ---------------------------------------------------------------------------
show_status() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║     CodexOS Network Status            ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo ""

    # Load state
    if [[ -f "$CODEX_NETWORK_JSON" ]]; then
        echo "State file: $CODEX_NETWORK_JSON"
        cat "$CODEX_NETWORK_JSON"
        echo ""
    fi

    # Show all interfaces
    echo -e "${BOLD}Network Interfaces:${NC}"
    ip -brief addr show 2>/dev/null || ifconfig -a 2>/dev/null
    echo ""

    # DNS
    echo -e "${BOLD}DNS Configuration:${NC}"
    cat /etc/resolv.conf 2>/dev/null | grep -v '^#' | grep -v '^$'
    echo ""

    # Connectivity
    echo -e "${BOLD}Connectivity:${NC}"
    if ping -c 1 -W 2 1.1.1.1 &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} IPv4 connectivity (1.1.1.1)"
    else
        echo -e "  ${RED}✗${NC} IPv4 connectivity (1.1.1.1)"
    fi

    if host -W 2 google.com &>/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} DNS resolution"
    else
        echo -e "  ${RED}✗${NC} DNS resolution"
    fi
    echo ""

    # Routing
    echo -e "${BOLD}Default Route:${NC}"
    ip route show default 2>/dev/null | head -3
    echo ""
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --eth-only)    MODE="eth-only"; shift ;;
            --wifi-only)   MODE="wifi-only"; shift ;;
            --status)      MODE="status"; shift ;;
            --dns)         MODE="dns"; shift ;;
            --non-interactive) export CODEX_NONINTERACTIVE=1; shift ;;
            -h|--help)
                echo "Usage: codex-network-stack [OPTIONS]"
                echo ""
                echo "  (no args)         Full network initialization"
                echo "  --eth-only        Only configure Ethernet"
                echo "  --wifi-only       Only configure WiFi"
                echo "  --status          Show current network status"
                echo "  --dns             Only configure DNS"
                echo "  --non-interactive Skip interactive WiFi wizard"
                echo "  -h, --help        Show this help"
                exit 0
                ;;
            *) shift ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    ensure_dirs

    log_info "Network stack starting (mode=$MODE)"

    case "$MODE" in
        status)
            show_status
            return 0
            ;;
        dns)
            configure_dns
            return 0
            ;;
    esac

    echo ""
    echo -e "${BOLD}CodexOS Network Initialization${NC}"
    echo ""

    local ethernet_ok=false
    local wifi_ok=false

    # --- Step 1: DNS ---
    if [[ "$MODE" == "full" ]]; then
        configure_dns
    fi

    # --- Step 2: Ethernet ---
    if [[ "$MODE" == "full" || "$MODE" == "eth-only" ]]; then
        step "Detecting Ethernet interfaces..."
        local eth_iface
        eth_iface="$(detect_ethernet)"

        if [[ -n "$eth_iface" ]]; then
            if configure_ethernet "$eth_iface"; then
                ethernet_ok=true
            fi
        else
            info "No Ethernet interface detected"
        fi
    fi

    # --- Step 3: WiFi (if Ethernet failed or wifi-only) ---
    if [[ "$ethernet_ok" == "false" ]] && [[ "$MODE" == "full" || "$MODE" == "wifi-only" ]]; then
        if setup_wifi; then
            wifi_ok=true
        fi
    fi

    # --- Step 4: Final connectivity test ---
    if [[ "$ethernet_ok" == "true" || "$wifi_ok" == "true" ]]; then
        step "Validating connectivity..."
        if ! test_connectivity; then
            warn "Network interfaces are up but connectivity test failed."
            warn "DNS or routing may need manual configuration."
        fi
    else
        warn "No network connectivity established."
        warn "Run 'codex-wifi-wizard' to configure WiFi manually."
        write_state "none" "none" ""
    fi

    log_info "Network stack completed (eth=$ethernet_ok wifi=$wifi_ok)"
    echo ""
}

main "$@"
