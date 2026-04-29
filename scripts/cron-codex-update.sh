#!/usr/bin/env bash
# =============================================================================
# CodexOS Lite — Automatic Codex Update Script (cron)
# =============================================================================
# Checks for new Codex CLI releases and updates if available.
#
# Install as a cron job:
#   0 */6 * * * /usr/local/bin/cron-codex-update
#
# Usage (standalone):
#   cron-codex-update                # Check and update
#   cron-codex-update --check        # Report only, don't update
#   cron-codex-update --force        # Update even if same version
#
# Configuration file: /persist/config/auto-update.conf
#   enabled=true|false               # Enable/disable auto-updates
#   interval=6                       # Check interval in hours
#   channel=stable|preview           # Release channel
#   lock_wait=3600                   # Max seconds to wait for lock (default: 1h)
# =============================================================================
set -euo pipefail

# ── Cleanup ──────────────────────────────────────────────────────────────────
_CLEANUP_DIRS=""
_cleanup() {
    [ -n "${_CLEANUP_DIRS:-}" ] && rm -rf $_CLEANUP_DIRS 2>/dev/null || true
}

# ── Configuration ─────────────────────────────────────────────────────────────
CONFIG_FILE="${CODEX_CONFIG:-/persist/config}/auto-update.conf"
LOG_DIR="${CODEX_LOGS:-/persist/logs}"
LOG_FILE="$LOG_DIR/codex-auto-update.log"
LOCK_FILE="/run/codex/codex-update.lock"
CODEX_BIN="${CODEX_BIN:-/usr/local/bin/codex}"
SETUP_SCRIPT="${SETUP_SCRIPT:-/usr/local/bin/setup-codex}"
GITHUB_REPO="openai/codex"
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases"

CHECK_ONLY=false
FORCE=false

# ── Defaults (overridden by config file) ─────────────────────────────────────
ENABLED=true
INTERVAL=6
CHANNEL="stable"
LOCK_WAIT=3600

# ── Logging ───────────────────────────────────────────────────────────────────
log() {
    local level="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local msg="[$ts] [$level] $*"
    echo "$msg"
    mkdir -p "$LOG_DIR"
    echo "$msg" >> "$LOG_FILE"
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() { [ "${DEBUG:-0}" = "1" ] && log "DEBUG" "$@" || true; }

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)   CHECK_ONLY=true; shift ;;
        --force)   FORCE=true; shift ;;
        --debug)   DEBUG=1; shift ;;
        --help|-h)
            echo "Usage: $0 [--check] [--force] [--debug]"
            echo "  --check   Report status without updating"
            echo "  --force   Update even if same version"
            echo "  --debug   Enable debug logging"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Load configuration ───────────────────────────────────────────────────────
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # Source the config (safe — only known variables)
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue

            # Trim whitespace
            key="$(echo "$key" | xargs)"
            value="$(echo "$value" | xargs)"

            case "$key" in
                enabled)   ENABLED="$value" ;;
                interval)  INTERVAL="$value" ;;
                channel)   CHANNEL="$value" ;;
                lock_wait) LOCK_WAIT="$value" ;;
            esac
        done < "$CONFIG_FILE"
        log_debug "Config loaded: enabled=$ENABLED interval=${INTERVAL}h channel=$CHANNEL"
    fi
}

# ── Check if auto-update is enabled ──────────────────────────────────────────
check_enabled() {
    if [ "$ENABLED" != "true" ]; then
        log_info "Auto-update is disabled in $CONFIG_FILE"
        exit 0
    fi
}

# ── Acquire lock (prevent concurrent updates) ────────────────────────────────
acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")"
    local lock_fd
    exec {lock_fd}>"$LOCK_FILE" 2>/dev/null || {
        log_warn "Could not open lock file"
        return 1
    }

    if ! flock -w "$LOCK_WAIT" "$lock_fd" 2>/dev/null; then
        log_warn "Could not acquire update lock (another update may be running)"
        return 1
    fi

    log_debug "Lock acquired"
    return 0
}

# ── Get current installed version ────────────────────────────────────────────
get_current_version() {
    if [ ! -x "$CODEX_BIN" ]; then
        echo ""
        return
    fi

    "$CODEX_BIN" --version 2>/dev/null | head -1 | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo ""
}

# ── Get latest available version from GitHub ─────────────────────────────────
get_latest_version() {
    local api_url
    case "$CHANNEL" in
        stable)
            api_url="$GITHUB_API/latest"
            ;;
        preview)
            api_url="$GITHUB_API"
            ;;
        *)
            log_error "Unknown channel: $CHANNEL"
            exit 1
            ;;
    esac

    local version
    version="$(curl -fsSL --connect-timeout 15 "$api_url" 2>/dev/null \
        | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^ "]+"' | sed 's/.*"//;s/"$//' | head -1)"

    if [ -z "$version" ]; then
        log_error "Could not fetch latest version from GitHub"
        return 1
    fi

    echo "$version"
}

# ── Compare versions ─────────────────────────────────────────────────────────
# Returns 0 if $1 >= $2, 1 if $1 < $2
version_gte() {
    local v1="$1" v2="$2"

    # Strip leading 'v' if present
    v1="${v1#v}"
    v2="${v2#v}"

    # Use sort -V for version comparison
    local sorted
    sorted="$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -1)"

    [ "$sorted" = "$v2" ]
}

# ── Perform the update ───────────────────────────────────────────────────────
do_update() {
    local new_version="$1"

    log_info "Updating Codex CLI to $new_version..."

    # Use the setup script if available
    if [ -x "$SETUP_SCRIPT" ]; then
        log_debug "Using setup-codex.sh for update"
        if FORCE_OUTPUT="$(FORCE=true CODEX_VERSION="$new_version" CHANNEL="$CHANNEL" "$SETUP_SCRIPT" 2>&1)"; then
            log_info "Update successful: $new_version"
            return 0
        else
            log_error "Update failed: $FORCE_OUTPUT"
            return 1
        fi
    fi

    # Fallback: direct download
    log_info "Downloading Codex CLI $new_version..."

    local arch_triple
    case "$(uname -m)" in
        x86_64|amd64)  arch_triple="x86_64-unknown-linux-musl" ;;
        aarch64|arm64) arch_triple="aarch64-unknown-linux-musl" ;;
        *)
            log_error "Unsupported architecture: $(uname -m)"
            return 1
            ;;
    esac

    local filename="codex-${arch_triple}.tar.gz"
    local url="https://github.com/${GITHUB_REPO}/releases/download/${new_version}/${filename}"

    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS="${_CLEANUP_DIRS:-} $tmpdir"
    trap _cleanup EXIT

    # Download
    if ! curl -fsSL --connect-timeout 30 -o "$tmpdir/$filename" "$url"; then
        log_error "Download failed: $url"
        return 1
    fi

    # Verify size
    local dl_size
    dl_size="$(stat -c%s "$tmpdir/$filename" 2>/dev/null || echo 0)"
    if [ "$dl_size" -lt 1048576 ]; then
        log_error "Downloaded file too small (${dl_size} bytes) — possible error page"
        return 1
    fi

    # Extract and install
    tar xzf "$tmpdir/$filename" -C "$tmpdir" 2>/dev/null || {
        log_error "Extraction failed"
        return 1
    }

    local binary
    binary="$(find "$tmpdir" -name 'codex' -type f ! -name '*.tar.gz' | head -1)"
    if [ -z "$binary" ]; then
        log_error "Binary not found in archive"
        return 1
    fi

    # Backup current binary
    if [ -x "$CODEX_BIN" ]; then
        cp "$CODEX_BIN" "${CODEX_BIN}.bak.$(date +%s)"
    fi

    # Install new binary
    cp "$binary" "$CODEX_BIN"
    chmod 755 "$CODEX_BIN"

    # Verify
    local new_ver
    new_ver="$("$CODEX_BIN" --version 2>/dev/null | head -1 || echo "unknown")"
    log_info "Codex CLI updated to: $new_ver"

    # Cleanup old backups (keep last 3)
    ls -t "${CODEX_BIN}".bak.* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true

    return 0
}

# ── Log rotation ─────────────────────────────────────────────────────────────
rotate_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        return
    fi

    local log_size
    log_size="$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)"

    # Rotate if > 10MB
    if [ "$log_size" -gt 10485760 ]; then
        mv "$LOG_FILE" "${LOG_FILE}.1"
        gzip "${LOG_FILE}.1" 2>/dev/null || true
        log_info "Log rotated"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    # Rotate logs first
    rotate_logs

    log_info "=== Codex auto-update check ==="

    # Load configuration
    load_config
    check_enabled

    # Acquire lock
    if ! acquire_lock; then
        exit 0  # Don't fail — just skip
    fi

    # Get versions
    local current latest
    current="$(get_current_version)"
    latest="$(get_latest_version)"

    if [ -z "$latest" ]; then
        log_error "Could not determine latest version. Skipping."
        exit 1
    fi

    log_info "Current: ${current:-not installed}"
    log_info "Latest:  $latest ($CHANNEL channel)"

    # Check mode: report and exit
    if $CHECK_ONLY; then
        if [ "$current" = "$latest" ]; then
            echo "STATUS: up-to-date ($latest)"
            exit 0
        else
            echo "STATUS: update available ($current -> $latest)"
            exit 100  # Non-zero to indicate update available
        fi
    fi

    # Compare versions
    if [ "$current" = "$latest" ] && [ "$FORCE" != "true" ]; then
        log_info "Already up to date. No action needed."
        exit 0
    fi

    if version_gte "$current" "$latest" && [ "$FORCE" != "true" ]; then
        log_info "Current version ($current) >= latest ($latest). No action needed."
        exit 0
    fi

    # Perform update
    if do_update "$latest"; then
        log_info "=== Update complete: $current -> $latest ==="

        # Post-update: log to system log
        logger -t codex-update "Codex CLI updated to $latest" 2>/dev/null || true
    else
        log_error "=== Update FAILED ==="
        exit 1
    fi
}

main "$@"
