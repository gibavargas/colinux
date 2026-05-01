#!/usr/bin/env bash
# =============================================================================
# CoLinux Desktop — Electron Codex Desktop Installer (standalone)
# =============================================================================
# Installs the Electron Codex Desktop app on Alpine Linux.
# This is the standalone version that can be run on any Alpine system.
#
# Usage:
#   sudo ./setup-electron-codex.sh
#   sudo ./setup-electron-codex.sh --update    # Update existing installation
#   sudo ./setup-electron-codex.sh --uninstall # Remove installation
#
# Environment variables:
#   CODEX_DESKTOP_REPO   — GitHub repo URL (default: nicepkg/codex-desktop)
#   CODEX_DESKTOP_BRANCH — Git branch (default: main)
#   NODE_VERSION         — Node.js version (default: 20)
#   INSTALL_DIR          — Installation directory (default: /opt/codex-desktop)
# =============================================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────
INSTALL_DIR="${INSTALL_DIR:-/opt/codex-desktop}"
CODEX_DESKTOP_REPO="${CODEX_DESKTOP_REPO:-https://github.com/nicepkg/codex-desktop}"
CODEX_DESKTOP_BRANCH="${CODEX_DESKTOP_BRANCH:-main}"
NODE_VERSION="${NODE_VERSION:-20}"
LOG_DIR="/persist/logs"
LOG_FILE="${LOG_DIR}/electron-codex-install.log"
BIN_DIR="/usr/local/bin"
ACTION="install"

# ── Colors ─────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

log()   { echo -e "${GREEN}[setup-electron-codex]${NC} $*"; }
warn()  { echo -e "${YELLOW}[setup-electron-codex]${NC} WARNING: $*" >&2; }
error() { echo -e "${RED}[setup-electron-codex]${NC} ERROR: $*" >&2; }

# ── Parse arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --update)    ACTION="update"; shift ;;
        --uninstall) ACTION="uninstall"; shift ;;
        --install)   ACTION="install"; shift ;;
        --help|-h)
            echo "Usage: $0 [--install|--update|--uninstall]"
            echo ""
            echo "  --install    Fresh install (default)"
            echo "  --update     Update existing installation"
            echo "  --uninstall  Remove Electron Codex Desktop"
            exit 0
            ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Check root ─────────────────────────────────────────────────────────────
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root (use sudo)."
        exit 1
    fi
}

# ── Step 1: Install Node.js ───────────────────────────────────────────────
install_nodejs() {
    log "Installing Node.js ${NODE_VERSION}..."

    if command -v node >/dev/null 2>&1; then
        local ver
        ver="$(node --version 2>/dev/null || echo '0')"
        if [[ "$ver" == v"${NODE_VERSION}".* ]]; then
            log "Node.js ${ver} already installed."
            return 0
        fi
    fi

    if [[ -f /etc/alpine-release ]]; then
        apk add --no-cache nodejs npm 2>/dev/null || true
    elif command -v apt-get >/dev/null 2>&1; then
        curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -
        apt-get install -y nodejs
    fi

    if command -v node >/dev/null 2>&1; then
        log "Node.js $(node --version) installed."
    else
        warn "Node.js installation may have issues."
    fi
}

# ── Step 2: Install Electron build dependencies ───────────────────────────
install_electron_deps() {
    log "Installing Electron runtime dependencies..."

    if [[ -f /etc/alpine-release ]]; then
        apk add --no-cache \
            nss \
            at-spi2-core \
            at-spi2-atk \
            libnotify \
            gtk+3.0 \
            libsecret \
            xdg-utils \
            linux-pam \
            2>/dev/null || true
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get install -y --no-install-recommends \
            libnss3 \
            libatk1.0-0 \
            libatk-bridge2.0-0 \
            libcups2 \
            libdrm2 \
            libxkbcommon0 \
            libxcomposite1 \
            libxdamage1 \
            libxrandr2 \
            libgbm1 \
            libpango-1.0-0 \
            libcairo2 \
            libasound2 \
            libatspi2.0-0 \
            libnotify4 \
            xdg-utils \
            2>/dev/null || true
    fi
}

# ── Step 3: Clone and build Electron app ──────────────────────────────────
clone_and_build() {
    log "Cloning codex-desktop from $CODEX_DESKTOP_REPO..."

    local build_dir
    build_dir="$(mktemp -d)"

    if ! git clone --depth 1 --branch "$CODEX_DESKTOP_BRANCH" \
            "$CODEX_DESKTOP_REPO" "$build_dir/codex-desktop" 2>/dev/null; then
        error "Failed to clone repository: $CODEX_DESKTOP_REPO"
        rm -rf "$build_dir"
        return 1
    fi

    cd "$build_dir/codex-desktop"

    log "Installing npm dependencies..."
    npm install --no-audit --no-fund 2>&1 | tee -a "$LOG_FILE" || true

    log "Building Electron Codex Desktop..."
    npm run build 2>&1 | tee -a "$LOG_FILE" || {
        warn "Build step failed — creating fallback wrapper..."
        create_fallback_wrapper
        rm -rf "$build_dir"
        return 0
    }

    # Try packaging
    npm run package -- --linux 2>/dev/null || true

    rm -rf "$build_dir"
}

# ── Step 4: Install to /opt/codex-desktop ────────────────────────────────
install_app() {
    log "Installing to $INSTALL_DIR..."

    mkdir -p "$INSTALL_DIR/app"
    mkdir -p "$INSTALL_DIR/config"

    # Create launcher
    cat > "$INSTALL_DIR/codex-desktop" <<'WRAPPER'
#!/bin/bash
# CoLinux Desktop — Electron Codex Desktop launcher
set -euo pipefail

CODEX_DESKTOP_DIR="/opt/codex-desktop"
ELECTRON_APP="${CODEX_DESKTOP_DIR}/app"

export ELECTRON_ENABLE_LOGGING=1

if [[ -x "$ELECTRON_APP/codex-desktop" ]]; then
    exec "$ELECTRON_APP/codex-desktop" "$@"
elif command -v electron >/dev/null 2>&1 && [[ -d "$ELECTRON_APP" ]]; then
    exec electron "$ELECTRON_APP" "$@"
elif [[ -f "$ELECTRON_APP/main.js" ]] && command -v electron >/dev/null 2>&1; then
    exec electron "$ELECTRON_APP/main.js" "$@"
else
    echo "ERROR: Codex Desktop not properly installed." >&2
    echo "Run: sudo setup-electron-codex.sh" >&2
    exit 1
fi
WRAPPER
    chmod 755 "$INSTALL_DIR/codex-desktop"

    # Create minimal Electron wrapper if not already built
    if [[ ! -f "$INSTALL_DIR/app/package.json" ]]; then
        create_fallback_wrapper
    fi

    # Config
    cat > "$INSTALL_DIR/config/config.json" <<'CONFIG'
{
    "theme": "dark",
    "fontSize": 14,
    "autoUpdate": true,
    "apiKeySource": "env",
    "codexCliPath": "/usr/local/bin/codex"
}
CONFIG

    # Symlink to bin
    ln -sf "$INSTALL_DIR/codex-desktop" "$BIN_DIR/codex-desktop"

    log "Installed to $INSTALL_DIR"
}

# ── Create fallback Electron wrapper ──────────────────────────────────────
create_fallback_wrapper() {
    log "Creating fallback Electron wrapper..."

    mkdir -p "$INSTALL_DIR/app"

    cat > "$INSTALL_DIR/app/package.json" <<'PKGJSON'
{
    "name": "codex-desktop",
    "version": "1.0.0",
    "description": "Codex Desktop — Electron wrapper for OpenAI Codex CLI",
    "main": "main.js",
    "scripts": {
        "start": "electron ."
    },
    "dependencies": {
        "electron": "^28.0.0"
    }
}
PKGJSON

    cat > "$INSTALL_DIR/app/main.js" <<'MAINJS'
const { app, BrowserWindow } = require('electron');
const path = require('path');

let mainWindow;

function createWindow() {
    mainWindow = new BrowserWindow({
        width: 1200,
        height: 800,
        title: 'Codex Desktop',
        backgroundColor: '#1e1e1e',
        webPreferences: {
            nodeIntegration: false,
            contextIsolation: true
        }
    });
    mainWindow.loadFile(path.join(__dirname, 'index.html'));
    mainWindow.on('closed', () => { mainWindow = null; });
}

app.whenReady().then(createWindow);
app.on('window-all-closed', () => { app.quit(); });
MAINJS

    cat > "$INSTALL_DIR/app/index.html" <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Codex Desktop</title>
    <style>
        body { margin: 0; padding: 20px; background: #1e1e1e; color: #d4d4d4; font-family: monospace; }
        h1 { color: #569cd6; }
        #terminal { background: #1e1e1e; border: 1px solid #3c3c3c; border-radius: 4px; padding: 10px; min-height: 400px; }
    </style>
</head>
<body>
    <h1>Codex Desktop</h1>
    <div id="terminal">
        <span style="color: #4ec9b0;">Codex Desktop is running.</span><br><br>
        Open a terminal and type <code style="color: #ce9178;">codex</code> to start the Codex CLI.<br><br>
        To install full Electron app: <code style="color: #ce9178;">sudo setup-electron-codex.sh --update</code>
    </div>
</body>
</html>
HTML

    (cd "$INSTALL_DIR/app" && npm install --no-audit --no-fund 2>/dev/null) || true
}

# ── Step 5: Create .desktop file ─────────────────────────────────────────
create_desktop_file() {
    log "Creating .desktop file..."

    mkdir -p /usr/share/applications
    mkdir -p /usr/share/icons/hicolor/scalable/apps

    cat > /usr/share/applications/codex-desktop.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Codex Desktop
Comment=OpenAI Codex Desktop App
Exec=/opt/codex-desktop/codex-desktop %U
Icon=codex-desktop
Terminal=false
Categories=Development;IDE;
StartupNotify=true
MimeType=x-scheme-handler/codex;
DESKTOP
    chmod 644 /usr/share/applications/codex-desktop.desktop

    cat > /usr/share/icons/hicolor/scalable/apps/codex-desktop.svg <<'ICON'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
    <rect width="128" height="128" rx="16" fill="#1e1e1e"/>
    <text x="64" y="80" text-anchor="middle" font-family="monospace" font-size="48" fill="#569cd6">C</text>
</svg>
ICON

    log ".desktop file created."
}

# ── Step 6: Set up auto-update ───────────────────────────────────────────
setup_auto_update() {
    log "Setting up auto-update cron..."

    if [[ -f /etc/alpine-release ]]; then
        mkdir -p /etc/periodic/6h
        cat > /etc/periodic/6h/codex-desktop-update <<'CRON'
#!/bin/sh
LOG="/persist/logs/codex-desktop-update.log"
mkdir -p /persist/logs
echo "=== Codex Desktop update check: $(date) ===" >> "$LOG"
cd /opt/codex-desktop/app 2>/dev/null && npm update --no-audit >> "$LOG" 2>&1 || echo "  update failed" >> "$LOG"
echo "" >> "$LOG"
CRON
        chmod 755 /etc/periodic/6h/codex-desktop-update
    else
        # systemd timer
        cat > /etc/systemd/system/codex-desktop-update.timer <<'TIMER'
[Unit]
Description=Codex Desktop Auto-Update Timer

[Timer]
OnCalendar=*-*-* 00/6:00:00
Persistent=true

[Install]
WantedBy=timers.target
TIMER

        cat > /etc/systemd/system/codex-desktop-update.service <<'SVC'
[Unit]
Description=Codex Desktop Auto-Update
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'cd /opt/codex-desktop/app && npm update --no-audit'
SVC

        systemctl daemon-reload 2>/dev/null || true
        systemctl enable codex-desktop-update.timer 2>/dev/null || true
    fi

    log "Auto-update configured."
}

# ── Uninstall ─────────────────────────────────────────────────────────────
do_uninstall() {
    log "Uninstalling Codex Desktop..."

    rm -rf "$INSTALL_DIR"
    rm -f "$BIN_DIR/codex-desktop"
    rm -f /usr/share/applications/codex-desktop.desktop
    rm -f /usr/share/icons/hicolor/scalable/apps/codex-desktop.svg

    if [[ -f /etc/alpine-release ]]; then
        rm -f /etc/periodic/6h/codex-desktop-update
    else
        systemctl disable codex-desktop-update.timer 2>/dev/null || true
        rm -f /etc/systemd/system/codex-desktop-update.*
    fi

    log "Codex Desktop uninstalled."
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
    mkdir -p "$LOG_DIR"

    {
        echo "=== Codex Desktop setup started at $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="

        case "$ACTION" in
            uninstall)
                do_uninstall
                ;;
            install)
                check_root
                install_nodejs
                install_electron_deps
                clone_and_build || create_fallback_wrapper
                install_app
                create_desktop_file
                setup_auto_update
                ;;
            update)
                check_root
                install_electron_deps
                clone_and_build || create_fallback_wrapper
                install_app
                log "Update complete."
                ;;
        esac

        echo "=== Codex Desktop setup completed at $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
    } 2>&1 | tee "$LOG_FILE"

    if [[ "$ACTION" != "uninstall" ]]; then
        log "Done! Launch with: codex-desktop (or from GNOME Applications)"
    fi
}

main "$@"
