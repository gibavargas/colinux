#!/bin/bash
# setup-electron-codex.sh — Install Electron Codex Desktop app on Alpine
# Part of CoLinux Desktop
#
# This script:
#   1. Installs Node.js and build dependencies
#   2. Optionally clones a pinned codex-desktop commit
#   3. Builds the Linux Electron wrapper only from locked dependencies
#   4. Installs to /opt/codex-desktop/
#   5. Creates .desktop file for GNOME integration
#   6. Sets up auto-update for the Electron app
#
# Usage:
#   sudo setup-electron-codex.sh
#   setup-electron-codex.sh --update    # Update existing installation
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────
INSTALL_DIR="/opt/codex-desktop"
CODEX_DESKTOP_REPO="${CODEX_DESKTOP_REPO:-https://github.com/nicepkg/codex-desktop}"
CODEX_DESKTOP_BRANCH="${CODEX_DESKTOP_BRANCH:-main}"
CODEX_DESKTOP_COMMIT="${CODEX_DESKTOP_COMMIT:-}"
NODE_VERSION="${NODE_VERSION:-22}"
LOG_DIR="/persist/logs"
LOG_FILE="$LOG_DIR/electron-codex-install.log"
BIN_DIR="/usr/local/bin"

# ── Colors ─────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

log()    { echo -e "${GREEN}[setup-electron-codex]${NC} $*"; }
warn()   { echo -e "${YELLOW}[setup-electron-codex]${NC} WARNING: $*" >&2; }
error()  { echo -e "${RED}[setup-electron-codex]${NC} ERROR: $*" >&2; }

# ── Check root ─────────────────────────────────────────────────────────────
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root (use sudo)."
        error "  sudo setup-electron-codex.sh"
        exit 1
    fi
}

# ── Step 1: Install Node.js ───────────────────────────────────────────────
install_nodejs() {
    log "Installing Node.js ${NODE_VERSION}..."

    if command -v node >/dev/null 2>&1; then
        local installed_ver
        installed_ver="$(node --version 2>/dev/null | sed 's/^v//' || echo '0')"
        if [[ "$installed_ver" == "$NODE_VERSION".* ]]; then
            log "Node.js ${installed_ver} already installed, skipping."
            return 0
        fi
    fi

    # Install Node.js from Alpine repos
    if [[ -f /etc/alpine-release ]]; then
        apk add --no-cache nodejs npm 2>/dev/null || {
            warn "Failed to install Node.js from Alpine repos."
            return 1
        }
    else
        warn "Non-Alpine system detected. Please install Node.js ${NODE_VERSION} manually."
    fi

    if command -v node >/dev/null 2>&1; then
        log "Node.js $(node --version) installed."
    else
        warn "Node.js installation may have failed. Continuing anyway..."
    fi
}

# ── Step 2: Install build dependencies ────────────────────────────────────
install_build_deps() {
    log "Installing Electron build dependencies..."

    if [[ -f /etc/alpine-release ]]; then
        apk add --no-cache \
            electron \
            npm \
            git \
            p7zip \
            nss \
            at-spi2-core \
            libnotify \
            gtk+3.0 \
            libsecret \
            libsoup3 \
            webkit2gtk-4.1 \
            2>/dev/null || {
            warn "Some Alpine packages were not available; using distro packages only."
        }
    fi
}

# ── Step 3: Clone and build ──────────────────────────────────────────────
clone_and_build() {
    if [[ -z "$CODEX_DESKTOP_COMMIT" ]]; then
        warn "Refusing to clone mutable branch '$CODEX_DESKTOP_BRANCH' as root without CODEX_DESKTOP_COMMIT."
        warn "Installing the local fallback wrapper instead."
        install_prebuilt_electron
        return 0
    fi
    if [[ ! "$CODEX_DESKTOP_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]]; then
        error "CODEX_DESKTOP_COMMIT must be a full 40-character hexadecimal commit SHA."
        return 1
    fi

    log "Cloning pinned codex-desktop commit $CODEX_DESKTOP_COMMIT from $CODEX_DESKTOP_REPO..."

    local build_dir
    build_dir="$(mktemp -d)"

    if ! git clone --no-checkout --branch "$CODEX_DESKTOP_BRANCH"             "$CODEX_DESKTOP_REPO" "$build_dir/codex-desktop" 2>/dev/null; then
        error "Failed to clone repository: $CODEX_DESKTOP_REPO"
        rm -rf "$build_dir"
        return 1
    fi

    cd "$build_dir/codex-desktop"
    git fetch --depth 1 origin "$CODEX_DESKTOP_COMMIT" 2>/dev/null || {
        error "Failed to fetch pinned commit: $CODEX_DESKTOP_COMMIT"
        rm -rf "$build_dir"
        return 1
    }
    git checkout --detach "$CODEX_DESKTOP_COMMIT" 2>/dev/null || {
        error "Failed to checkout pinned commit: $CODEX_DESKTOP_COMMIT"
        rm -rf "$build_dir"
        return 1
    }

    if [[ ! -f package-lock.json ]]; then
        warn "Pinned app has no package-lock.json; refusing unpinned npm install as root."
        install_prebuilt_electron
        rm -rf "$build_dir"
        return 0
    fi

    log "Installing npm dependencies from package-lock.json..."
    npm ci --no-audit --no-fund 2>&1 | tee -a "$LOG_FILE" || {
        warn "npm ci failed. Installing fallback launcher."
        install_prebuilt_electron
        rm -rf "$build_dir"
        return 0
    }

    log "Building Electron Codex Desktop..."
    npm run build 2>&1 | tee -a "$LOG_FILE" || {
        warn "Build failed. Installing fallback launcher."
        install_prebuilt_electron
        rm -rf "$build_dir"
        return 0
    }

    # Try packaging
    npm run package -- --linux 2>/dev/null || true

    rm -rf "$build_dir"
}

# ── Step 4: Install to /opt/codex-desktop ────────────────────────────────
install_to_opt() {
    log "Installing to $INSTALL_DIR..."

    mkdir -p "$INSTALL_DIR"

    # Create a wrapper script that launches Electron with Codex
    cat > "$INSTALL_DIR/codex-desktop" <<'WRAPPER'
#!/bin/bash
# CoLinux Desktop — Electron Codex Desktop launcher
# This wrapper launches the Codex Desktop Electron application.

set -euo pipefail

CODEX_DESKTOP_DIR="/opt/codex-desktop"
ELECTRON_APP="${CODEX_DESKTOP_DIR}/app"

# Set Electron flags for best compatibility
export ELECTRON_DISABLE_GPU="${ELECTRON_DISABLE_GPU:-}"
export ELECTRON_ENABLE_LOGGING=1

# Launch the app
if [[ -x "$ELECTRON_APP/codex-desktop" ]]; then
    exec "$ELECTRON_APP/codex-desktop" "$@"
elif command -v electron >/dev/null 2>&1 && [[ -d "$CODEX_DESKTOP_DIR/app" ]]; then
    exec electron "$CODEX_DESKTOP_DIR/app" "$@"
elif [[ -f "$CODEX_DESKTOP_DIR/app.js" ]]; then
    if command -v electron >/dev/null 2>&1; then
        exec electron "$CODEX_DESKTOP_DIR/app.js" "$@"
    else
        echo "ERROR: electron runtime not found." >&2
        echo "Run: sudo apk add electron  (Alpine)" >&2
        exit 1
    fi
else
    echo "Codex Desktop not properly installed." >&2
    echo "Run: sudo setup-electron-codex.sh" >&2
    exit 1
fi
WRAPPER

    chmod 755 "$INSTALL_DIR/codex-desktop"

    # Create app directory structure
    mkdir -p "$INSTALL_DIR/app"
    mkdir -p "$INSTALL_DIR/config"

    # Create default config
    cat > "$INSTALL_DIR/config/config.json" <<'CONFIG'
{
    "theme": "dark",
    "fontSize": 14,
    "autoUpdate": true,
    "apiKeySource": "env",
    "codexCliPath": "/usr/local/bin/codex"
}
CONFIG

    # Install Codex Desktop via npm if not built from source
    if [[ ! -d "$INSTALL_DIR/app/node_modules" ]]; then
        log "Setting up Electron app via npm..."
        cd "$INSTALL_DIR/app"

        # Create a minimal Electron wrapper
        cat > "$INSTALL_DIR/app/package.json" <<'PKGJSON'
{
    "name": "codex-desktop",
    "version": "1.0.0",
    "description": "Codex Desktop — Electron wrapper for OpenAI Codex CLI",
    "main": "main.js",
    "scripts": {
        "start": "electron .",
        "build": "electron-builder --linux"
    },
    "dependencies": {
        "electron": "^28.0.0"
    }
}
PKGJSON

        # Create minimal main process
        cat > "$INSTALL_DIR/app/main.js" <<'MAINJS'
const { app, BrowserWindow } = require('electron');
const path = require('path');
const { spawn } = require('child_process');

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

    // Load the Codex web UI or a local HTML page
    mainWindow.loadFile(path.join(__dirname, 'index.html'));

    mainWindow.on('closed', () => {
        mainWindow = null;
    });
}

app.whenReady().then(createWindow);

app.on('window-all-closed', () => {
    app.quit();
});
MAINJS

        # Create minimal HTML UI
        cat > "$INSTALL_DIR/app/index.html" <<'HTML'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Codex Desktop</title>
    <style>
        body {
            margin: 0;
            padding: 20px;
            background-color: #1e1e1e;
            color: #d4d4d4;
            font-family: 'DejaVu Sans Mono', monospace;
        }
        h1 { color: #569cd6; margin-bottom: 10px; }
        #terminal {
            background-color: #1e1e1e;
            border: 1px solid #3c3c3c;
            border-radius: 4px;
            padding: 10px;
            font-family: 'DejaVu Sans Mono', monospace;
            font-size: 14px;
            min-height: 400px;
            white-space: pre-wrap;
            overflow-y: auto;
        }
        .status { color: #4ec9b0; }
        .error { color: #f44747; }
    </style>
</head>
<body>
    <h1>Codex Desktop</h1>
    <div id="terminal"><span class="status">Codex Desktop is running.</span>
Type your request below or use the Codex CLI in a terminal.

To use Codex CLI: open a terminal and type 'codex'</div>
</body>
</html>
HTML

        # Do not install Electron from npm as root; use the distro Electron package.
        warn "Fallback launcher created; Electron runtime must come from distro packages."
    fi

    log "Codex Desktop installed to $INSTALL_DIR"
}

# ── Step 5: Create .desktop file ─────────────────────────────────────────
create_desktop_file() {
    log "Creating .desktop file..."

    mkdir -p /usr/share/applications

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

    # Create a simple icon (SVG placeholder)
    mkdir -p /usr/share/icons/hicolor/scalable/apps
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
    log "Setting up auto-update for Codex Desktop..."

    mkdir -p /etc/periodic/6h

    cat > /etc/periodic/6h/codex-desktop-update <<'CRONSCRIPT'
#!/bin/sh
# CoLinux Desktop — Electron app npm auto-update intentionally disabled.
# External app updates must be installed from a pinned CODEX_DESKTOP_COMMIT.

LOG="/persist/logs/codex-desktop-update.log"
mkdir -p /persist/logs
printf '%s
' "=== Codex Desktop update check: $(date) ==="     "  npm auto-update disabled; run setup-electron-codex.sh with a pinned CODEX_DESKTOP_COMMIT"     "" >> "$LOG"
CRONSCRIPT

    chmod 755 /etc/periodic/6h/codex-desktop-update

    log "Auto-update placeholder installed (npm updates disabled)."
}

# ── Fallback: install prebuilt Electron ───────────────────────────────────
install_prebuilt_electron() {
    log "Attempting to install prebuilt Electron app..."

    mkdir -p "$INSTALL_DIR/app"

    # Create a simple wrapper that uses the system's codex CLI
    cat > "$INSTALL_DIR/codex-desktop" <<'WRAPPER'
#!/bin/bash
# CoLinux Desktop — Fallback launcher
# Launches Codex CLI in a dedicated GNOME Terminal window

set -euo pipefail

if command -v gnome-terminal >/dev/null 2>&1; then
    exec gnome-terminal --title="Codex Desktop" -- bash -c "codex 2>/dev/null || { echo 'Codex CLI not found. Run: codex-update'; bash; }"
elif command -v foot >/dev/null 2>&1; then
    exec foot -T "Codex Desktop" bash -c "codex 2>/dev/null || { echo 'Codex CLI not found. Run: codex-update'; bash; }"
else
    exec bash -c "codex 2>/dev/null || { echo 'Codex CLI not found. Run: codex-update'; bash; }"
fi
WRAPPER
    chmod 755 "$INSTALL_DIR/codex-desktop"

    log "Fallback launcher installed."
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
    mkdir -p "$LOG_DIR"

    {
        echo "=== Codex Desktop Installation started at $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
        check_root
        install_nodejs
        install_build_deps
        clone_and_build || install_prebuilt_electron
        install_to_opt
        create_desktop_file
        setup_auto_update
        echo "=== Codex Desktop Installation completed at $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
    } 2>&1 | tee "$LOG_FILE"

    log "Installation complete! Codex Desktop is available at $INSTALL_DIR"
    log "Launch it from GNOME Applications or run: codex-desktop"
}

main "$@"
