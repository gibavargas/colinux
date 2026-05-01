#!/usr/bin/env bash
# ============================================================================
# CoLinux — Unified WiFi Wizard
# ============================================================================
# Comprehensive WiFi setup wizard for ALL CoLinux editions (TTY + GUI).
# Supports both iwd and wpa_supplicant backends with automatic fallback.
#
# Usage:
#   codex-wifi-wizard                 — Interactive wizard
#   codex-wifi-wizard --scan          — Scan and list networks
#   codex-wifi-wizard --connect SSID  — Connect to specific SSID
#   codex-wifi-wizard --status        — Show connection status
#   codex-wifi-wizard --disconnect    — Disconnect current WiFi
#   codex-wifi-wizard --backend iwd   — Force specific backend
#
# Config: /persist/config/wifi.conf
# Saved networks: /persist/config/wifi/
# Logs: /persist/logs/network.log
# ============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
WIFI_CONFIG_DIR="/persist/config/wifi"
WIFI_CONFIG_FILE="/persist/config/wifi.conf"
WIFI_LOG="/persist/logs/network.log"
CODEX_STATE_DIR="/run/codex"

# Defaults (overridden by config file)
CONFIG_ADAPTER="auto"
CONFIG_BACKEND="auto"
CONFIG_AUTO_CONNECT="true"

# Runtime
DETECTED_ADAPTER=""
DETECTED_BACKEND=""
SELECTED_ADAPTER=""
CURRENT_BACKEND=""

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
    local msg="[$ts] [$level] [wifi-wizard] $*"
    echo "$msg" >> "$WIFI_LOG" 2>/dev/null || true
}

log_info()  { log_msg "INFO"  "$*"; }
log_warn()  { log_msg "WARN"  "$*"; }
log_error() { log_msg "ERROR" "$*"; }

info()  { echo -e "${GREEN}[INFO]${NC} $*"; log_info "$*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; log_warn "$*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; log_error "$*"; }
die()   { error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Sanitize SSID for use in filenames (prevent path traversal)
# ---------------------------------------------------------------------------
safe_ssid() {
    echo "$1" | tr -cd 'a-zA-Z0-9_-' | head -c 32
}

# ---------------------------------------------------------------------------
# Ensure directories exist
# ---------------------------------------------------------------------------
ensure_dirs() {
    mkdir -p "$WIFI_CONFIG_DIR" 2>/dev/null || true
    mkdir -p "$(dirname "$WIFI_LOG")" 2>/dev/null || true
    mkdir -p "$CODEX_STATE_DIR" 2>/dev/null || true
    mkdir -p /var/lib/iwd 2>/dev/null || true
    chmod 700 /var/lib/iwd 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------
load_config() {
    if [[ -f "$WIFI_CONFIG_FILE" ]]; then
        while IFS='=' read -r key val; do
            key="$(echo "$key" | tr -d '[:space:]')"
            val="$(echo "$val" | tr -d '[:space:]' | sed 's/^"//;s/"$//')"
            case "$key" in
                ADAPTER)       CONFIG_ADAPTER="$val" ;;
                BACKEND)       CONFIG_BACKEND="$val" ;;
                AUTO_CONNECT)  CONFIG_AUTO_CONNECT="${val:-true}" ;;
            esac
        done < "$WIFI_CONFIG_FILE"
    fi
}

save_config() {
    cat > "$WIFI_CONFIG_FILE" <<EOF
ADAPTER=${SELECTED_ADAPTER:-auto}
BACKEND=${CURRENT_BACKEND:-auto}
AUTO_CONNECT=${CONFIG_AUTO_CONNECT}
KNOWN_NETWORKS=$(ls -1 "$WIFI_CONFIG_DIR"/*.conf 2>/dev/null | wc -l)
EOF
    chmod 600 "$WIFI_CONFIG_FILE"
    log_info "Configuration saved to $WIFI_CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# WiFi adapter detection
# ---------------------------------------------------------------------------
detect_adapters() {
    local adapters=()
    for iface in /sys/class/net/wlan* /sys/class/net/wlp*; do
        [[ -e "$iface" ]] || continue
        local name="${iface##*/}"
        # Check if interface is wireless
        if [[ -d "$iface/wireless" ]] || command -v iw &>/dev/null && iw dev "$name" info &>/dev/null; then
            adapters+=("$name")
        fi
    done

    if [[ ${#adapters[@]} -eq 0 ]]; then
        # Try ip link
        while IFS= read -r line; do
            local name
            name="$(echo "$line" | awk -F: '{print $2}' | tr -d ' ')"
            [[ -n "$name" ]] || continue
            if iw dev "$name" info &>/dev/null 2>&1; then
                adapters+=("$name")
            fi
        done < <(ip link show 2>/dev/null | grep -E '^[0-9]+: wl')
    fi

    printf '%s\n' "${adapters[@]}"
}

select_adapter() {
    local adapters
    mapfile -t adapters < <(detect_adapters)

    case ${#adapters[@]} in
        0)
            die "No WiFi adapters found. Check that your WiFi hardware is connected and enabled (rfkill unblock all)."
            ;;
        1)
            SELECTED_ADAPTER="${adapters[0]}"
            info "Using WiFi adapter: $SELECTED_ADAPTER"
            ;;
        *)
            if [[ "$CONFIG_ADAPTER" != "auto" ]] && [[ -n "$CONFIG_ADAPTER" ]]; then
                # Validate configured adapter
                for a in "${adapters[@]}"; do
                    if [[ "$a" == "$CONFIG_ADAPTER" ]]; then
                        SELECTED_ADAPTER="$CONFIG_ADAPTER"
                        info "Using configured adapter: $SELECTED_ADAPTER"
                        return
                    fi
                done
                warn "Configured adapter $CONFIG_ADAPTER not found — selecting interactively"
            fi

            if is_gui_mode; then
                SELECTED_ADAPTER="$(gui_select "Select WiFi Adapter" "${adapters[@]}")"
            else
                echo ""
                echo -e "${BOLD}Multiple WiFi adapters detected:${NC}"
                local i=1
                for a in "${adapters[@]}"; do
                    local desc="$a"
                    if command -v iwconfig &>/dev/null; then
                        desc="$(iwconfig "$a" 2>/dev/null | head -1 || echo "$a")"
                    fi
                    echo -e "  ${CYAN}$i)${NC} $desc"
                    ((i++))
                done
                echo ""
                read -rp "Select adapter [1-${#adapters[@]}]: " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#adapters[@]} ]]; then
                    SELECTED_ADAPTER="${adapters[$((choice-1))]}"
                else
                    die "Invalid selection."
                fi
            fi
            info "Selected adapter: $SELECTED_ADAPTER"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Backend detection and selection
# ---------------------------------------------------------------------------
detect_backend() {
    # Prefer iwd if available and functional, fall back to wpa_supplicant
    if [[ "$CONFIG_BACKEND" != "auto" ]]; then
        case "$CONFIG_BACKEND" in
            iwd)     DETECTED_BACKEND="iwd" ;;
            wpa*)    DETECTED_BACKEND="wpa_supplicant" ;;
            *)       warn "Unknown backend '$CONFIG_BACKEND' in config — auto-detecting"
        esac
    fi

    if [[ -z "$DETECTED_BACKEND" ]]; then
        if command -v iwctl &>/dev/null && pgrep -x iwd &>/dev/null; then
            DETECTED_BACKEND="iwd"
        elif command -v wpa_supplicant &>/dev/null; then
            DETECTED_BACKEND="wpa_supplicant"
        elif [[ -f /usr/sbin/iwd ]]; then
            DETECTED_BACKEND="iwd"
        elif [[ -f /usr/sbin/wpa_supplicant ]]; then
            DETECTED_BACKEND="wpa_supplicant"
        else
            die "No WiFi backend found. Install iwd or wpa_supplicant."
        fi
    fi

    CURRENT_BACKEND="$DETECTED_BACKEND"
    info "WiFi backend: $CURRENT_BACKEND"
    log_info "Using backend: $CURRENT_BACKEND"
}

ensure_backend_running() {
    case "$CURRENT_BACKEND" in
        iwd)
            if ! pgrep -x iwd &>/dev/null; then
                info "Starting iwd daemon..."
                mkdir -p /var/run/iwd 2>/dev/null || true
                if command -v iwd &>/dev/null; then
                    iwd &
                    sleep 1
                else
                    # Try systemctl
                    systemctl start iwd 2>/dev/null || \
                        rc-service iwd start 2>/dev/null || \
                        /usr/sbin/iwd &
                    sleep 1
                fi
                if ! pgrep -x iwd &>/dev/null; then
                    warn "Failed to start iwd — trying wpa_supplicant fallback"
                    CURRENT_BACKEND="wpa_supplicant"
                    ensure_backend_running
                    return
                fi
            fi
            ;;
        wpa_supplicant)
            if ! pgrep -f "wpa_supplicant.*${SELECTED_ADAPTER}" &>/dev/null; then
                info "Starting wpa_supplicant for $SELECTED_ADAPTER..."
                # Kill any stale wpa_supplicant on this interface
                pkill -f "wpa_supplicant.*${SELECTED_ADAPTER}" 2>/dev/null || true
                sleep 0.5
                mkdir -p /run/wpa_supplicant 2>/dev/null || true
                wpa_supplicant -B -i "$SELECTED_ADAPTER" -C /run/wpa_supplicant -P /run/wpa_supplicant/${SELECTED_ADAPTER}.pid 2>/dev/null || \
                    wpa_supplicant -B -i "$SELECTED_ADAPTER" -c /dev/null 2>/dev/null || \
                    die "Failed to start wpa_supplicant"
                sleep 1
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Adapter up
# ---------------------------------------------------------------------------
adapter_up() {
    local adapter="${1:-$SELECTED_ADAPTER}"
    info "Bringing up $adapter..."

    # Unblock radio if blocked
    if command -v rfkill &>/dev/null; then
        rfkill unblock wifi 2>/dev/null || true
        rfkill unblock all 2>/dev/null || true
    fi

    ip link set "$adapter" up 2>/dev/null || \
        ifconfig "$adapter" up 2>/dev/null || \
        warn "Failed to bring up $adapter"

    sleep 1
}

# ---------------------------------------------------------------------------
# Scanning
# ---------------------------------------------------------------------------
scan_networks_iwd() {
    # Scan using iwctl
    local adapter="$1"
    local scan_output

    # Trigger scan
    iwctl device "$adapter" scan 2>/dev/null || true
    sleep 3  # Wait for scan to complete

    # Get results
    scan_output="$(iwctl station "$adapter" get-networks 2>/dev/null)" || {
        warn "iwctl scan failed"
        return 1
    }

    # Parse: extract SSID, signal, security
    echo "$scan_output" | tail -n +4 | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Lines look like: "  network_name   psk     ***   ****"
        local ssid signal security
        ssid="$(echo "$line" | awk '{print $1}')"
        # Signal is the 4th column (or so)
        signal="$(echo "$line" | awk '{print $(NF-1)}')"
        security="$(echo "$line" | awk '{print $2}')"
        [[ "$ssid" == ">>"* ]] && ssid="${ssid#>> }"
        echo "$ssid|$signal|$security"
    done
}

scan_networks_wpa() {
    local adapter="$1"
    local scan_output

    if command -v wpa_cli &>/dev/null; then
        local ctrl="/run/wpa_supplicant/$adapter"
        if [[ ! -S "$ctrl" ]]; then
            ctrl="/run/wpa_supplicant/$adapter/$adapter"
        fi

        wpa_cli -i "$adapter" -p "$(dirname "$ctrl")" scan 2>/dev/null || true
        sleep 3
        scan_output="$(wpa_cli -i "$adapter" -p "$(dirname "$ctrl")" scan_results 2>/dev/null)" || {
            warn "wpa_cli scan failed"
            return 1
        }

        # Skip header line, parse bssid/freq/signal/flags/ssid
        echo "$scan_output" | tail -n +2 | while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local ssid signal security
            # Fields: bssid freq signal flags ssid
            signal="$(echo "$line" | awk '{print $3}')"
            security="$(echo "$line" | awk '{print $4}')"
            ssid="$(echo "$line" | awk '{for(i=5;i<=NF;i++) printf "%s%s",$i,(i<NF?OFS:"")}')"
            [[ -z "$ssid" || "$ssid" == "\\x00" ]] && continue
            echo "$ssid|$signal|$security"
        done
    else
        # Fallback: use iw
        if command -v iw &>/dev/null; then
            iw dev "$adapter" scan 2>/dev/null | awk '
                /BSS / { if (ssid != "") print ssid "|" signal "|" security; ssid=""; signal=""; security="" }
                /signal:/ { signal=$2 }
                /SSID:/ { ssid=$2; for(i=3;i<=NF;i++) ssid=ssid" "$i }
                /capability:/ {
                    security="Open"
                    if ($0 ~ /Privacy/) security="WPA"
                }
                /WPA:/ { security="WPA/WPA2" }
                /RSN:/ { security="WPA2/WPA3" }
                END { if (ssid != "") print ssid "|" signal "|" security }
            '
        fi
    fi
}

scan_networks() {
    local adapter="${1:-$SELECTED_ADAPTER}"
    info "Scanning for WiFi networks on $adapter..."
    log_info "Scanning networks on $adapter (backend=$CURRENT_BACKEND)"

    adapter_up "$adapter"
    ensure_backend_running

    local networks
    case "$CURRENT_BACKEND" in
        iwd)           networks="$(scan_networks_iwd "$adapter")" ;;
        wpa_supplicant) networks="$(scan_networks_wpa "$adapter")" ;;
    esac

    if [[ -z "$networks" ]]; then
        warn "No networks found. The adapter may not have proper driver support, or there are no networks in range."
        return 1
    fi

    # Sort by signal strength (descending), deduplicate
    echo "$networks" | sort -t'|' -k2 -rn | awk -F'|' '!seen[$1]++' | head -30
}

# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------
connect_iwd() {
    local ssid="$1"
    local password="${2:-}"
    local adapter="${3:-$SELECTED_ADAPTER}"

    info "Connecting to $ssid via iwd..."

    if [[ -n "$password" ]]; then
        # Write config for auto-reconnect
        local escaped_ssid
        escaped_ssid="$(echo "$ssid" | sed 's/\\/\\\\/g; s/ /\\ /g')"
        local safe_name
        safe_name="$(safe_ssid "$ssid")"
        local config_file="/var/lib/iwd/${safe_name}.psk"
        cat > "$config_file" <<EOF
[Security]
Passphrase=${password}

[Settings]
AutoConnect=true
EOF
        chmod 600 "$config_file"
    else
        # Open network
        local escaped_ssid
        escaped_ssid="$(echo "$ssid" | sed 's/\\/\\\\/g; s/ /\\ /g')"
        local safe_name
        safe_name="$(safe_ssid "$ssid")"
        local config_file="/var/lib/iwd/${safe_name}.open"
        cat > "$config_file" <<EOF
[Settings]
AutoConnect=true
EOF
        chmod 600 "$config_file"
    fi

    iwctl station "$adapter" connect "$ssid" 2>&1
}

connect_wpa() {
    local ssid="$1"
    local password="${2:-}"
    local adapter="${3:-$SELECTED_ADAPTER}"

    info "Connecting to $ssid via wpa_supplicant..."

    local ctrl_dir="/run/wpa_supplicant"
    local ctrl="$ctrl_dir/$adapter"

    # Create network config
    local wpa_conf="$WIFI_CONFIG_DIR/$(safe_ssid "$ssid").conf"

    local safe_ssid_esc
    safe_ssid_esc="$(printf '%s' "$ssid" | sed 's/["\\]/\\&/g')"

    cat > "$wpa_conf" <<EOF
ctrl_interface=$ctrl_dir
update_config=1

network={
    ssid="$safe_ssid_esc"
    scan_ssid=1
EOF

    if [[ -n "$password" ]]; then
        # Use wpa_passphrase to hash the password
        if command -v wpa_passphrase &>/dev/null; then
            local hashed
            hashed="$(wpa_passphrase "$ssid" "$password" 2>/dev/null | grep 'psk=')"
            if [[ -n "$hashed" ]]; then
                echo "$hashed" >> "$wpa_conf"
            else
                error "Failed to hash WiFi password — connection aborted"
                return 1
            fi
        else
            error "wpa_passphrase not available — cannot securely configure WiFi"
            return 1
        fi
    else
        echo "    key_mgmt=NONE" >> "$wpa_conf"
    fi

    echo "}" >> "$wpa_conf"
    chmod 600 "$wpa_conf"

    # Configure wpa_supplicant
    if [[ -S "$ctrl" ]] || [[ -S "$ctrl_dir/$adapter/$adapter" ]]; then
        local socket_path
        if [[ -S "$ctrl" ]]; then
            socket_path="$ctrl"
        else
            socket_path="$ctrl_dir/$adapter/$adapter"
        fi
        wpa_cli -i "$adapter" -p "$ctrl_dir" remove_network all 2>/dev/null || true
        wpa_cli -i "$adapter" -p "$ctrl_dir" add_network 2>/dev/null || true
        wpa_cli -i "$adapter" -p "$ctrl_dir" set_network 0 ssid "\"$safe_ssid_esc\"" 2>/dev/null
        wpa_cli -i "$adapter" -p "$ctrl_dir" set_network 0 scan_ssid 1 2>/dev/null
        if [[ -n "$password" ]]; then
            # Write a temporary config to feed PSK safely (avoids password in ps/process list)
            local tmp_psk_conf
            tmp_psk_conf="$(mktemp /tmp/wpa_psk_XXXXXX.conf)"
            cat > "$tmp_psk_conf" <<PSKEOF
network={
    ssid="$safe_ssid_esc"
    psk="$password"
}
PSKEOF
            local hashed_psk
            hashed_psk="$(wpa_passphrase -f "$tmp_psk_conf" 2>/dev/null | grep 'psk=' | head -1 | sed 's/^[[:space:]]*//' | cut -d= -f2-)"
            rm -f "$tmp_psk_conf"
            if [[ -n "$hashed_psk" ]]; then
                wpa_cli -i "$adapter" -p "$ctrl_dir" set_network 0 psk "\"$hashed_psk\"" 2>/dev/null
            fi
        else
            wpa_cli -i "$adapter" -p "$ctrl_dir" set_network 0 key_mgmt NONE 2>/dev/null
        fi
        wpa_cli -i "$adapter" -p "$ctrl_dir" enable_network 0 2>/dev/null
        wpa_cli -i "$adapter" -p "$ctrl_dir" select_network 0 2>/dev/null
    else
        # Restart wpa_supplicant with our config
        pkill -f "wpa_supplicant.*$adapter" 2>/dev/null || true
        sleep 0.5
        wpa_supplicant -B -i "$adapter" -c "$wpa_conf" -P /run/wpa_supplicant/${adapter}.pid
    fi
}

connect_network() {
    local ssid="$1"
    local password="${2:-}"
    local adapter="${3:-$SELECTED_ADAPTER}"

    log_info "Connecting to $ssid on $adapter"

    case "$CURRENT_BACKEND" in
        iwd)           connect_iwd "$ssid" "$password" "$adapter" ;;
        wpa_supplicant) connect_wpa "$ssid" "$password" "$adapter" ;;
    esac

    # Wait for connection with DHCP
    info "Waiting for DHCP lease..."
    local max_wait=15
    local count=0
    while [[ $count -lt $max_wait ]]; do
        if ip addr show "$adapter" | grep -q 'inet '; then
            info "Got IP address!"
            break
        fi
        # Try to get DHCP
        if command -v dhcpcd &>/dev/null; then
            dhcpcd -n "$adapter" 2>/dev/null || dhcpcd "$adapter" 2>/dev/null
        elif command -v udhcpc &>/dev/null; then
            udhcpc -i "$adapter" -f -n -q 2>/dev/null &
        elif command -v dhclient &>/dev/null; then
            dhclient "$adapter" 2>/dev/null
        fi
        sleep 1
        ((count++))
    done

    # Validate connectivity
    if validate_connection; then
        info "Successfully connected to $ssid!"
        log_info "Connected to $ssid on $adapter"

        # Save config for auto-reconnect
        save_config

        # Save known network entry
        local known_file="$WIFI_CONFIG_DIR/known_$(safe_ssid "$ssid")"
        cat > "$known_file" <<EOF
SSID=$ssid
ADAPTER=$adapter
BACKEND=$CURRENT_BACKEND
CONNECTED=$(date -Iseconds)
EOF
        chmod 600 "$known_file"

        # Update network status
        update_network_status "wifi" "$adapter" "$ssid"
        return 0
    else
        error "Connection to $ssid failed or no connectivity."
        log_error "Failed to connect to $ssid"

        # Try fallback backend
        if [[ "$CURRENT_BACKEND" == "iwd" ]]; then
            warn "Trying fallback to wpa_supplicant..."
            CURRENT_BACKEND="wpa_supplicant"
            ensure_backend_running
            connect_network "$ssid" "$password" "$adapter"
            return $?
        fi
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
validate_connection() {
    local adapter="${1:-$SELECTED_ADAPTER}"
    local ip_addr
    ip_addr="$(ip -4 addr show "$adapter" 2>/dev/null | grep -oP 'inet \K[0-9.]+')" || true

    if [[ -z "$ip_addr" ]]; then
        return 1
    fi

    # Ping test
    if ping -c 1 -W 3 1.1.1.1 &>/dev/null; then
        return 0
    elif ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        return 0
    fi

    # DNS test as fallback
    if command -v nslookup &>/dev/null; then
        nslookup -timeout=3 example.com &>/dev/null && return 0
    fi

    return 1
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
show_status() {
    local adapter="${1:-$SELECTED_ADAPTER}"
    echo ""
    echo -e "${BOLD}=== WiFi Status ===${NC}"
    echo ""

    # Adapter info
    echo -e "  Adapter:  ${CYAN}$adapter${NC}"

    local state
    state="$(cat "/sys/class/net/$adapter/operstate" 2>/dev/null || echo "unknown")"
    echo -e "  State:    ${GREEN}$state${NC}"

    # IP address
    local ip_addr
    ip_addr="$(ip -4 addr show "$adapter" 2>/dev/null | grep -oP 'inet \K[0-9.]+')" || true
    echo -e "  IP:       ${CYAN}${ip_addr:-none}${NC}"

    # Connected SSID
    local ssid=""
    case "$CURRENT_BACKEND" in
        iwd)
            ssid="$(iwctl station "$adapter" show 2>/dev/null | grep 'Connected' | awk '{print $2}')" || true
            ;;
        wpa_supplicant)
            if command -v wpa_cli &>/dev/null; then
                ssid="$(wpa_cli -i "$adapter" status 2>/dev/null | grep '^ssid=' | cut -d= -f2)" || true
            fi
            ;;
    esac
    echo -e "  SSID:     ${CYAN}${ssid:-disconnected}${NC}"
    echo -e "  Backend:  ${CYAN}$CURRENT_BACKEND${NC}"

    # Signal
    if command -v iwconfig &>/dev/null; then
        local signal
        signal="$(iwconfig "$adapter" 2>/dev/null | grep 'Signal level' | grep -oP 'Signal level=\K[-0-9]+')" || true
        if [[ -n "$signal" ]]; then
            echo -e "  Signal:   ${YELLOW}${signal} dBm${NC}"
        fi
    fi

    # Known networks
    local known_count
    known_count="$(ls -1 "$WIFI_CONFIG_DIR"/known_* 2>/dev/null | wc -l)"
    if [[ "$known_count" -gt 0 ]]; then
        echo -e "  Known:    ${GREEN}${known_count} saved network(s)${NC}"
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# Disconnect
# ---------------------------------------------------------------------------
disconnect() {
    local adapter="${1:-$SELECTED_ADAPTER}"
    info "Disconnecting $adapter..."

    case "$CURRENT_BACKEND" in
        iwd)
            iwctl station "$adapter" disconnect 2>/dev/null || true
            ;;
        wpa_supplicant)
            if command -v wpa_cli &>/dev/null; then
                wpa_cli -i "$adapter" disconnect 2>/dev/null || true
            fi
            ;;
    esac

    # Release DHCP
    if command -v dhcpcd &>/dev/null; then
        dhcpcd -k "$adapter" 2>/dev/null || true
    fi

    ip addr flush dev "$adapter" 2>/dev/null || true
    log_info "Disconnected from WiFi on $adapter"
    update_network_status "disconnected" "$adapter" ""
    info "Disconnected."
}

# ---------------------------------------------------------------------------
# Network status JSON
# ---------------------------------------------------------------------------
update_network_status() {
    local mode="$1"   # wifi|ethernet|disconnected
    local iface="$2"
    local ssid="$3"
    local ip_addr=""
    ip_addr="$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[0-9.]+')" || true

    mkdir -p "$CODEX_STATE_DIR"
    cat > "$CODEX_STATE_DIR/network.json" <<EOF
{
    "mode": "$mode",
    "interface": "$iface",
    "ssid": "$ssid",
    "ip": "$ip_addr",
    "backend": "${CURRENT_BACKEND:-unknown}",
    "timestamp": "$(date -Iseconds)"
}
EOF
}

# ---------------------------------------------------------------------------
# GUI helpers
# ---------------------------------------------------------------------------
is_gui_mode() {
    [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]
}

gui_select() {
    local title="$1"; shift
    local items=("$@")

    if command -v dialog &>/dev/null && [[ -t 0 ]]; then
        # Use dialog (ncurses) — works even without X
        local menu_args=()
        local i=1
        for item in "${items[@]}"; do
            menu_args+=("$i" "$item")
            ((i++))
        done
        local result
        result="$(dialog --title "$title" --menu "$title" 15 60 ${#items[@]} "${menu_args[@]}" 2>&1 >/dev/tty)"
        echo "${items[$((result-1))]}"
    elif command -v whiptail &>/dev/null && [[ -t 0 ]]; then
        local menu_args=()
        local i=1
        for item in "${items[@]}"; do
            menu_args+=("$i" "$item")
            ((i++))
        done
        local result
        result="$(whiptail --title "$title" --menu "$title" 15 60 ${#items[@]} "${menu_args[@]}" 3>&1 1>&2 2>&3)"
        echo "${items[$((result-1))]}"
    elif command -v zenity &>/dev/null; then
        local args=(--list --title="$title" --column="" --column="Name")
        for item in "${items[@]}"; do
            args+=(FALSE "$item")
        done
        zenity "${args[@]}" 2>/dev/null
    elif command -v yad &>/dev/null; then
        local list=""
        for item in "${items[@]}"; do
            list+="$item\n"
        done
        echo -e "$list" | yad --list --title="$title" --column="Name" --print-column=0 2>/dev/null
    else
        # Fallback to text
        echo "${items[0]}"
    fi
}

gui_password() {
    local prompt="${1:-Enter WiFi password:}"

    if command -v dialog &>/dev/null && [[ -t 0 ]]; then
        dialog --title "WiFi Password" --passwordbox "$prompt" 10 50 2>&1 >/dev/tty
    elif command -v whiptail &>/dev/null && [[ -t 0 ]]; then
        whiptail --title "WiFi Password" --passwordbox "$prompt" 10 50 3>&1 1>&2 2>&3
    elif command -v zenity &>/dev/null; then
        zenity --password --title="WiFi Password" 2>/dev/null
    elif command -v yad &>/dev/null; then
        yad --password --title="WiFi Password" 2>/dev/null
    else
        read -rsp "$prompt" pw
        echo "$pw"
    fi
}

# ---------------------------------------------------------------------------
# Interactive Wizard (TTY mode)
# ---------------------------------------------------------------------------
wizard_tty() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║     CoLinux WiFi Setup Wizard         ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo ""

    # 1. Select adapter
    select_adapter

    # 2. Scan
    local networks
    networks="$(scan_networks)" || {
        echo ""
        read -rp "No networks found. Enter SSID manually? [y/N]: " manual
        if [[ "$manual" =~ ^[Yy]$ ]]; then
            read -rp "SSID: " manual_ssid
            read -rsp "Password (leave empty for open): " manual_pw
            echo ""
            connect_network "$manual_ssid" "$manual_pw"
            return
        fi
        return 1
    }

    # 3. Display networks
    echo ""
    echo -e "${BOLD}Available Networks:${NC}"
    echo -e "${BOLD} #   SSID                          Signal     Security${NC}"
    echo -e "───────────────────────────────────────────────────────"

    local i=1
    local ssids=()
    local securities=()
    while IFS='|' read -r ssid signal security; do
        [[ -z "$ssid" ]] && continue
        ssids+=("$ssid")
        securities+=("$security")
        printf " %2d  %-30s %-10s %s\n" "$i" "$ssid" "${signal:-?}" "${security:-unknown}"
        ((i++))
    done <<< "$networks"

    echo ""
    echo -e " ${CYAN}H)${NC} Hidden network (manual SSID entry)"
    echo -e " ${CYAN}S)${NC} Show connection status"
    echo -e " ${CYAN}Q)${NC} Quit"
    echo ""

    read -rp "Select network [1-$((i-1))]: " choice

    case "$choice" in
        [Qq]) exit 0 ;;
        [Ss]) show_status; exit 0 ;;
        [Hh])
            read -rp "Enter SSID: " manual_ssid
            [[ -z "$manual_ssid" ]] && die "SSID cannot be empty."
            read -rsp "Password (leave empty for open): " manual_pw
            echo ""
            connect_network "$manual_ssid" "$manual_pw"
            return
            ;;
        *)
            if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -lt $i ]]; then
                local sel_ssid="${ssids[$((choice-1))]}"
                local sel_sec="${securities[$((choice-1))]}"
                info "Selected: $sel_ssid ($sel_sec)"

                local password=""
                if [[ "$sel_sec" != "Open" && "$sel_sec" != "open" && "$sel_sec" != "open/"* ]]; then
                    read -rsp "Password for $sel_ssid: " password
                    echo ""
                fi

                connect_network "$sel_ssid" "$password"
                return
            else
                error "Invalid selection."
                exit 1
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Interactive Wizard (GUI mode)
# ---------------------------------------------------------------------------
wizard_gui() {
    select_adapter

    local networks
    networks="$(scan_networks)" || {
        gui_select "No networks found. Please check your adapter." "OK" 2>/dev/null || true
        return 1
    }

    local ssids=()
    local securities=()
    while IFS='|' read -r ssid signal security; do
        [[ -z "$ssid" ]] && continue
        ssids+=("$ssid")
        securities+=("$security")
    done <<< "$networks"

    if [[ ${#ssids[@]} -eq 0 ]]; then
        return 1
    fi

    local selected
    selected="$(gui_select "Select WiFi Network" "${ssids[@]}")"
    [[ -z "$selected" ]] && return 1

    local password=""
    # Find security for selected
    local sel_sec=""
    for i in "${!ssids[@]}"; do
        if [[ "${ssids[$i]}" == "$selected" ]]; then
            sel_sec="${securities[$i]}"
            break
        fi
    done

    if [[ "$sel_sec" != "Open" && "$sel_sec" != "open" ]]; then
        password="$(gui_password "Password for $selected:")"
    fi

    connect_network "$selected" "$password"
}

# ---------------------------------------------------------------------------
# Auto-reconnect
# ---------------------------------------------------------------------------
auto_reconnect() {
    [[ "$CONFIG_AUTO_CONNECT" != "true" ]] && return 1

    log_info "Attempting auto-reconnect..."
    info "Attempting WiFi auto-reconnect..."

    # Find most recently connected known network
    local latest_file=""
    local latest_time=0
    for f in "$WIFI_CONFIG_DIR"/known_*; do
        [[ -f "$f" ]] || continue
        local ftime
        ftime="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"
        if [[ "$ftime" -gt "$latest_time" ]]; then
            latest_time="$ftime"
            latest_file="$f"
        fi
    done

    if [[ -z "$latest_file" ]]; then
        log_info "No known networks for auto-reconnect"
        return 1
    fi

    local known_ssid known_adapter known_backend
    known_ssid="$(grep '^SSID=' "$latest_file" | cut -d= -f2)"
    known_adapter="$(grep '^ADAPTER=' "$latest_file" | cut -d= -f2)"
    known_backend="$(grep '^BACKEND=' "$latest_file" | cut -d= -f2)"

    [[ -z "$known_ssid" ]] && return 1

    # Use saved adapter if still present
    if [[ -n "$known_adapter" ]]; then
        SELECTED_ADAPTER="$known_adapter"
    else
        select_adapter
    fi

    if [[ -n "$known_backend" ]]; then
        CURRENT_BACKEND="$known_backend"
    fi

    adapter_up
    ensure_backend_running

    info "Reconnecting to $known_ssid..."
    # For auto-reconnect, let the backend handle it (configs are saved)
    case "$CURRENT_BACKEND" in
        iwd)
            iwctl station "$SELECTED_ADAPTER" connect "$known_ssid" 2>&1
            ;;
        wpa_supplicant)
            # wpa_supplicant should auto-reconnect from its config
            sleep 3
            ;;
    esac

    # Get DHCP
    sleep 2
    if command -v dhcpcd &>/dev/null; then
        dhcpcd -n "$SELECTED_ADAPTER" 2>/dev/null || true
    fi

    if validate_connection; then
        info "Auto-reconnected to $known_ssid"
        update_network_status "wifi" "$SELECTED_ADAPTER" "$known_ssid"
        return 0
    else
        warn "Auto-reconnect to $known_ssid failed"
        update_network_status "disconnected" "$SELECTED_ADAPTER" ""
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Parse CLI
# ---------------------------------------------------------------------------
parse_args() {
    local action="wizard"
    local force_backend=""
    local connect_ssid=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --scan)         action="scan"; shift ;;
            --connect)      action="connect"; connect_ssid="${2:-}"; shift 2 ;;
            --status)       action="status"; shift ;;
            --disconnect)   action="disconnect"; shift ;;
            --auto)         action="auto"; shift ;;
            --backend)      force_backend="$2"; shift 2 ;;
            --adapter)      CONFIG_ADAPTER="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: codex-wifi-wizard [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  (no args)          Interactive WiFi wizard"
                echo "  --scan             Scan and list available networks"
                echo "  --connect SSID     Connect to specific SSID"
                echo "  --status           Show current connection status"
                echo "  --disconnect       Disconnect from current network"
                echo "  --auto             Auto-reconnect to last known network"
                echo "  --backend TYPE     Force backend: iwd | wpa_supplicant"
                echo "  --adapter NAME     Force WiFi adapter"
                echo "  -h, --help         Show this help"
                exit 0
                ;;
            *) shift ;;
        esac
    done

    echo "$action|$connect_ssid|$force_backend"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    ensure_dirs
    load_config

    local parsed action connect_ssid force_backend
    parsed="$(parse_args "$@")"
    action="$(echo "$parsed" | cut -d'|' -f1)"
    connect_ssid="$(echo "$parsed" | cut -d'|' -f2)"
    force_backend="$(echo "$parsed" | cut -d'|' -f3)"

    # Select adapter early
    select_adapter

    # Detect backend
    if [[ -n "$force_backend" ]]; then
        CURRENT_BACKEND="$force_backend"
        info "Forced backend: $CURRENT_BACKEND"
    else
        detect_backend
    fi

    case "$action" in
        scan)
            local networks
            networks="$(scan_networks)" || exit 1
            echo ""
            echo -e "${BOLD}Available Networks:${NC}"
            echo -e "${BOLD} #   SSID                          Signal     Security${NC}"
            echo -e "───────────────────────────────────────────────────────"
            local i=1
            while IFS='|' read -r ssid signal security; do
                [[ -z "$ssid" ]] && continue
                printf " %2d  %-30s %-10s %s\n" "$i" "$ssid" "${signal:-?}" "${security:-unknown}"
                ((i++))
            done <<< "$networks"
            echo ""
            ;;
        connect)
            [[ -z "$connect_ssid" ]] && die "Usage: codex-wifi-wizard --connect SSID"
            adapter_up
            ensure_backend_running
            read -rsp "Password (leave empty for open): " password
            echo ""
            connect_network "$connect_ssid" "${password:-}"
            ;;
        status)
            show_status
            ;;
        disconnect)
            disconnect
            ;;
        auto)
            auto_reconnect
            ;;
        wizard)
            if is_gui_mode; then
                wizard_gui
            else
                wizard_tty
            fi
            ;;
    esac
}

main "$@"
