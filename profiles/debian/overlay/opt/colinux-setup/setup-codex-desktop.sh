#!/usr/bin/env bash
# =============================================================================
# CoLinux Desktop — Setup Codex Desktop (Electron) App
# =============================================================================
# Downloads the latest Codex Desktop release from OpenAI, wraps it in an
# Electron shell for Linux, and installs it to /opt/codex-desktop/.
#
# Reference: https://github.com/ilysenko/codex-desktop-linux
#
# This script is designed to run:
#   1. During the build process (to pre-install in the ISO)
#   2. At runtime via codex-desktop-autoupdate (to update post-install)
#
# Usage:
#   ./setup-codex-desktop.sh [--version latest|X.Y.Z] [--prefix /opt/codex-desktop]
#   ./setup-codex-desktop.sh --build-deps    # Install build dependencies only
#   ./setup-codex-desktop.sh --check         # Check for updates without installing
#
# Environment:
#   CODEX_DESKTOP_CHANNEL  — stable|preview (default: stable)
#   CODEX_DESKTOP_FORCE    — Force reinstall (default: false)
# =============================================================================
set -euo pipefail

# ── Cleanup ──────────────────────────────────────────────────────────────────
_CLEANUP_DIRS=""
_cleanup() {
    [ -n "${_CLEANUP_DIRS:-}" ] && rm -rf "${_CLEANUP_DIRS}" 2>/dev/null || true
}
trap _cleanup EXIT

# ── Configuration ─────────────────────────────────────────────────────────────
INSTALL_DIR="${INSTALL_DIR:-/opt/codex-desktop}"
CODEX_DESKTOP_WRAPPER_REPO="https://github.com/ilysenko/codex-desktop-linux"
CODEX_DESKTOP_WRAPPER_BRANCH="main"
CODEX_DESKTOP_WRAPPER_COMMIT="${CODEX_DESKTOP_WRAPPER_COMMIT:-43c8bd1b5d4ab2eb4be8eb474528d6050c51db9a}"
CODEX_REPO="openai/codex"
GITHUB_API="https://api.github.com/repos"
CHANNEL="${CODEX_DESKTOP_CHANNEL:-stable}"
FORCE="${CODEX_DESKTOP_FORCE:-false}"
VERSION="${CODEX_DESKTOP_VERSION:-latest}"
BUILD_DEPS_ONLY=false
CHECK_ONLY=false

# ── State tracking ────────────────────────────────────────────────────────────
STATE_DIR="${STATE_DIR:-/var/lib/codex-desktop}"
STATE_FILE="$STATE_DIR/state.json"
ROLLBACK_DIR="$STATE_DIR/rollback"
CURRENT_VERSION_FILE="$STATE_DIR/current-version"
WRAPPER_VERSION_FILE="$STATE_DIR/wrapper-version"

# ── Colors ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "\n${BLUE}━━━ $* ━━━${NC}\n"; }

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)       VERSION="$2"; shift 2 ;;
        --prefix)        INSTALL_DIR="$2"; shift 2 ;;
        --channel)       CHANNEL="$2"; shift 2 ;;
        --force)         FORCE=true; shift ;;
        --build-deps)    BUILD_DEPS_ONLY=true; shift ;;
        --check)         CHECK_ONLY=true; shift ;;
        --help|-h)
            echo "Usage: $0 [--version VER] [--prefix DIR] [--channel CH] [--force] [--check] [--build-deps]"
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# ── State management ─────────────────────────────────────────────────────────
ensure_state_dir() {
    mkdir -p "$STATE_DIR" "$ROLLBACK_DIR"
}

get_current_version() {
    if [ -f "$CURRENT_VERSION_FILE" ]; then
        cat "$CURRENT_VERSION_FILE"
    else
        echo ""
    fi
}

set_current_version() {
    echo "$1" > "$CURRENT_VERSION_FILE"
}

get_current_wrapper_version() {
    if [ -f "$WRAPPER_VERSION_FILE" ]; then
        cat "$WRAPPER_VERSION_FILE"
    else
        echo ""
    fi
}

# ── Rollback ──────────────────────────────────────────────────────────────────
create_rollback_point() {
    local label="$1"
    local rb_dir="$ROLLBACK_DIR/$(date +%Y%m%d-%H%M%S)-$label"
    mkdir -p "$rb_dir"

    if [ -d "$INSTALL_DIR" ] && [ "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
        cp -a "$INSTALL_DIR" "$rb_dir/app"
    fi

    # Keep only the last 3 rollback points
    ls -td "$ROLLBACK_DIR"/*/ 2>/dev/null | tail -n +4 | xargs rm -rf 2>/dev/null || true

    log_info "Rollback point created: $rb_dir"
}

rollback() {
    local rb_dir
    rb_dir="$(ls -td "$ROLLBACK_DIR"/*/ 2>/dev/null | head -1)"
    if [ -z "$rb_dir" ] || [ ! -d "$rb_dir/app" ]; then
        log_error "No rollback points available"
        return 1
    fi

    log_info "Rolling back to: $rb_dir"
    create_rollback_point "pre-rollback"
    rm -rf "${INSTALL_DIR:?}"/*
    cp -a "$rb_dir/app"/* "$INSTALL_DIR"/
    log_info "Rollback complete"
}

# ── Install build dependencies ───────────────────────────────────────────────
install_build_deps() {
    log_step "Installing build dependencies"

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y --no-install-recommends \
            curl \
            ca-certificates \
            git \
            p7zip-full \
            7zip \
            jq \
            libarchive-tools \
            xorriso \
            > /dev/null 2>&1
        log_info "Build dependencies installed"
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl ca-certificates git p7zip jq xorriso
        log_info "Build dependencies installed (Alpine)"
    else
        log_error "No supported package manager found"
        return 1
    fi
}

# ── Get latest Codex Desktop release from OpenAI ────────────────────────────
get_latest_codex_release() {
    local api_url="$GITHUB_API/$CODEX_REPO/releases/latest"
    local release_info

    release_info="$(curl -fsSL --connect-timeout 15 "$api_url" 2>/dev/null)" || {
        log_error "Failed to fetch release info from GitHub"
        return 1
    }

    local tag_name
    tag_name="$(echo "$release_info" | jq -r '.tag_name // empty' 2>/dev/null)"
    if [ -z "$tag_name" ]; then
        log_error "Could not determine latest release tag"
        return 1
    fi

    echo "$tag_name"
}

# ── Get latest wrapper version ───────────────────────────────────────────────
get_latest_wrapper_commit() {
    case "$CODEX_DESKTOP_WRAPPER_COMMIT" in
        [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
            echo "$CODEX_DESKTOP_WRAPPER_COMMIT"
            ;;
        *)
            log_error "CODEX_DESKTOP_WRAPPER_COMMIT must be a full 40-character commit SHA"
            return 1
            ;;
    esac
}

# ── Download Codex Desktop (macOS release) ───────────────────────────────────
download_codex_desktop() {
    local version="$1"
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS="${_CLEANUP_DIRS:-} $tmpdir"

    log_info "Downloading Codex Desktop v$version..."

    # OpenAI releases Codex Desktop as a macOS .dmg or .zip
    # The codex-desktop-linux project extracts the app bundle from the macOS release
    # and wraps it with Electron for Linux.

    # Find the darwin release asset
    local release_info download_url asset_name asset_digest
    release_info="$(curl -fsSL "$GITHUB_API/$CODEX_REPO/releases/tags/$version" 2>/dev/null)" || \
        release_info="$(curl -fsSL "$GITHUB_API/$CODEX_REPO/releases/latest" 2>/dev/null)" || {
        log_error "Failed to fetch release info"
        return 1
    }

    # Look for macOS assets
    asset_name="$(echo "$release_info" | jq -r '.assets[].name' 2>/dev/null \
        | grep -iE 'darwin|macos|mac' | grep -iE '\.dmg|\.zip' | head -1)" || true

    if [ -z "$asset_name" ]; then
        log_warn "No macOS release asset found for v$version"
        log_warn "The Electron wrapper may need to be built differently"
        # Try to find any release asset
        asset_name="$(echo "$release_info" | jq -r '.assets[].name' 2>/dev/null | head -1)" || true
    fi

    if [ -n "$asset_name" ]; then
        download_url="$(echo "$release_info" | jq -r --arg name "$asset_name" \
            '.assets[] | select(.name==$name) | .browser_download_url // empty' 2>/dev/null | head -1)"
        asset_digest="$(echo "$release_info" | jq -r --arg name "$asset_name" \
            '.assets[] | select(.name==$name) | .digest // empty' 2>/dev/null | head -1)"
        asset_digest="${asset_digest#sha256:}"
    fi

    if [ -z "$download_url" ]; then
        log_error "Could not determine download URL for Codex Desktop v$version"
        log_error "Visit https://github.com/$CODEX_REPO/releases to check available assets"
        return 1
    fi

    log_info "Downloading: $download_url"
    curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 \
        -o "$tmpdir/codex-desktop-release" "$download_url" || {
        log_error "Download failed"
        return 1
    }

    # Verify size (should be > 10MB for a real app)
    local dl_size
    dl_size="$(stat -c%s "$tmpdir/codex-desktop-release" 2>/dev/null || echo 0)"
    if [ "$dl_size" -lt 10485760 ]; then
        log_error "Download suspiciously small (${dl_size} bytes) — may be an error page"
        return 1
    fi

    if [[ ! "$asset_digest" =~ ^[0-9a-fA-F]{64}$ ]]; then
        log_error "No GitHub SHA256 digest for $asset_name; refusing unverified desktop asset"
        return 1
    fi
    local actual_digest
    actual_digest="$(sha256sum "$tmpdir/codex-desktop-release" | awk '{print $1}')"
    if [ "$actual_digest" != "$asset_digest" ]; then
        log_error "SHA256 mismatch for $asset_name"
        log_error "Expected: $asset_digest"
        log_error "Actual:   $actual_digest"
        return 1
    fi
    log_info "SHA256 digest verified for $asset_name"

    echo "$tmpdir"
}

# ── Build Electron wrapper ───────────────────────────────────────────────────
build_electron_wrapper() {
    local codex_release_dir="$1"
    local wrapper_dir="$2"
    local output_dir="$INSTALL_DIR"
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS="${_CLEANUP_DIRS:-} $tmpdir"

    log_step "Building Electron wrapper for Codex Desktop"

    # Clone the codex-desktop-linux wrapper and pin it to the resolved commit
    local wrapper_commit
    wrapper_commit="$(get_latest_wrapper_commit)"
    if [ "$wrapper_commit" = "unknown" ]; then
        log_error "Could not resolve codex-desktop-linux wrapper commit"
        return 1
    fi

    log_info "Cloning codex-desktop-linux wrapper at $wrapper_commit..."
    rm -rf "$wrapper_dir"
    git clone --depth 1 "$CODEX_DESKTOP_WRAPPER_REPO" "$wrapper_dir" || {
        log_error "Failed to clone codex-desktop-linux wrapper"
        return 1
    }
    (cd "$wrapper_dir" && git fetch --depth 1 origin "$wrapper_commit" && git checkout --detach "$wrapper_commit") || {
        log_error "Failed to pin codex-desktop-linux wrapper to $wrapper_commit"
        return 1
    }

    # The wrapper project typically has:
    #   - An Electron main process (main.js or similar)
    #   - A package.json that specifies Electron as a dependency
    #   - A build script that extracts the Codex binary from the macOS app bundle

    # Check if wrapper has a build script
    if [ -f "$wrapper_dir/build.sh" ]; then
        log_info "Running wrapper build script..."
        (cd "$wrapper_dir" && bash build.sh "$codex_release_dir" "$output_dir") || {
            log_error "Wrapper build script failed"
            return 1
        }
    elif [ -f "$wrapper_dir/package.json" ]; then
        log_info "Building wrapper via npm..."
        (cd "$wrapper_dir" && npm install --production 2>/dev/null) || {
            log_warn "npm install failed, attempting manual setup"
        }

        # If there's an Electron app, copy it
        if [ -f "$wrapper_dir/main.js" ] || [ -f "$wrapper_dir/src/main.js" ]; then
            log_info "Assembling Electron app..."
            mkdir -p "$output_dir"
            cp -a "$wrapper_dir"/{main.js,package.json,*.html,*.css,assets,src,resources} \
                "$output_dir"/ 2>/dev/null || true

            # Copy the Codex binary from the release
            local codex_bin
            codex_bin="$(find "$codex_release_dir" -name 'codex' -type f -executable 2>/dev/null | head -1)" || true
            if [ -n "$codex_bin" ]; then
                mkdir -p "$output_dir/bin"
                cp "$codex_bin" "$output_dir/bin/codex"
                chmod 755 "$output_dir/bin/codex"
                log_info "Codex binary installed to $output_dir/bin/codex"
            fi

            # Install Electron if not present
            if [ -f "$wrapper_dir/package.json" ]; then
                local electron_version
                electron_version="$(jq -r '.dependencies.electron // .devDependencies.electron // "latest"' \
                    "$wrapper_dir/package.json" 2>/dev/null)"
                if [ -n "$electron_version" ] && [ "$electron_version" != "null" ]; then
                    (cd "$wrapper_dir" && npm install "electron@$electron_version" 2>/dev/null) || true
                    # Copy node_modules
                    if [ -d "$wrapper_dir/node_modules/electron" ]; then
                        cp -a "$wrapper_dir/node_modules" "$output_dir/" 2>/dev/null || true
                    fi
                fi
            fi
        else
            log_error "No main.js found in wrapper — cannot build Electron app"
            return 1
        fi
    else
        log_error "codex-desktop-linux wrapper has no build.sh or package.json"
        log_info "The wrapper project structure may have changed"
        log_info "Visit: $CODEX_DESKTOP_WRAPPER_REPO"
        return 1
    fi

    # Create launcher script
    create_launcher_script "$output_dir"

    # Create .desktop file
    create_desktop_entry

    log_info "Electron wrapper built successfully"
}

# ── Create launcher script ───────────────────────────────────────────────────
create_launcher_script() {
    local app_dir="$1"
    local launcher="$app_dir/codex-desktop"

    cat > "$launcher" <<'LAUNCHER_EOF'
#!/usr/bin/env bash
# CoLinux Desktop — Codex Desktop Launcher
# Launches the Codex Desktop Electron application.
set -euo pipefail

APP_DIR="/opt/codex-desktop"
LOG_DIR="/persist/logs"
LOG_FILE="$LOG_DIR/codex-desktop.log"

mkdir -p "$LOG_DIR"

# Log startup
echo "[$(date -Iseconds)] Codex Desktop starting" >> "$LOG_FILE"

# Set Electron flags for Linux compatibility
export ELECTRON_DISABLE_GPU_SANDBOX=1
export ELECTRON_ENABLE_LOGGING=1

# Prefer Wayland, fall back to X11
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    export ELECTRON_OZONE_PLATFORM_HINT=wayland
fi

# Launch
if [ -f "$APP_DIR/main.js" ]; then
    exec "$APP_DIR/node_modules/.bin/electron" "$APP_DIR/main.js" "$@" 2>>"$LOG_FILE"
elif [ -f "$APP_DIR/start.sh" ]; then
    exec bash "$APP_DIR/start.sh" "$@" 2>>"$LOG_FILE"
elif command -v electron >/dev/null 2>&1; then
    exec electron "$APP_DIR" "$@" 2>>"$LOG_FILE"
else
    echo "ERROR: Cannot find Electron runtime or start script" >&2
    echo "Check $APP_DIR for the application files" >&2
    exit 1
fi
LAUNCHER_EOF

    chmod 755 "$launcher"
    log_info "Launcher created: $launcher"
}

# ── Create .desktop entry ────────────────────────────────────────────────────
create_desktop_entry() {
    local desktop_file="/usr/share/applications/codex-desktop.desktop"

    cat > "$desktop_file" <<DESKTOP_EOF
[Desktop Entry]
Name=Codex Desktop
Comment=OpenAI Codex Desktop — AI Coding Assistant
Exec=/opt/codex-desktop/codex-desktop
Icon=codex-desktop
Terminal=false
Type=Application
Categories=Development;IDE;
Keywords=AI;Codex;OpenAI;Coding;Assistant;
StartupNotify=true
StartupWMClass=codex-desktop
X-GNOME-Autostart-enabled=true
DESKTOP_EOF

    chmod 644 "$desktop_file"

    # Create autostart entry
    mkdir -p /etc/xdg/autostart
    cat > /etc/xdg/autostart/codex-desktop.desktop <<AUTOSTART_EOF
[Desktop Entry]
Name=Codex Desktop
Comment=Auto-start Codex Desktop on login
Exec=/opt/codex-desktop/codex-desktop
Icon=codex-desktop
Terminal=false
Type=Application
Categories=Development;IDE;
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=3
AUTOSTART_EOF

    chmod 644 /etc/xdg/autostart/codex-desktop.desktop
    log_info "Desktop entries created"
}

# ── Verify installation ──────────────────────────────────────────────────────
verify_installation() {
    log_info "Verifying installation..."

    local errors=0

    if [ ! -d "$INSTALL_DIR" ]; then
        log_error "Install directory missing: $INSTALL_DIR"
        errors=$((errors + 1))
    fi

    if [ ! -x "$INSTALL_DIR/codex-desktop" ]; then
        log_error "Launcher not executable: $INSTALL_DIR/codex-desktop"
        errors=$((errors + 1))
    fi

    if [ ! -f /usr/share/applications/codex-desktop.desktop ]; then
        log_warn "Desktop entry missing"
        errors=$((errors + 1))
    fi

    if [ $errors -eq 0 ]; then
        log_info "Installation verified: OK"
        return 0
    else
        log_error "Installation has $errors error(s)"
        return 1
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    log_step "CoLinux Desktop — Codex Desktop Setup"

    if $BUILD_DEPS_ONLY; then
        install_build_deps
        exit 0
    fi

    ensure_state_dir

    # Check current state
    local current_ver current_wrapper
    current_ver="$(get_current_version)"
    current_wrapper="$(get_current_wrapper_version)"

    log_info "Current Codex version:    ${current_ver:-not installed}"
    log_info "Current wrapper version:  ${current_wrapper:-not installed}"
    log_info "Install directory:        $INSTALL_DIR"
    log_info "Update channel:           $CHANNEL"

    # Resolve version
    if [ "$VERSION" = "latest" ]; then
        VERSION="$(get_latest_codex_release)" || {
            log_error "Could not determine latest Codex version"
            exit 1
        }
        log_info "Latest Codex version: $VERSION"
    fi

    # Check mode
    if $CHECK_ONLY; then
        if [ "$current_ver" = "$VERSION" ]; then
            echo "STATUS: up-to-date ($VERSION)"
            exit 0
        else
            echo "STATUS: update available ($current_ver -> $VERSION)"
            exit 100
        fi
    fi

    # Skip if already current (unless forced)
    if [ "$current_ver" = "$VERSION" ] && [ "$FORCE" != "true" ]; then
        log_info "Already at version $VERSION. Use --force to reinstall."
        exit 0
    fi

    # Install build deps
    install_build_deps

    # Create rollback point
    if [ -n "$current_ver" ]; then
        create_rollback_point "v$current_ver"
    fi

    # Download Codex Desktop release
    local release_dir
    release_dir="$(download_codex_desktop "$VERSION")" || exit 1

    # Clone/build wrapper
    local wrapper_dir
    wrapper_dir="$(mktemp -d)"
    _CLEANUP_DIRS="${_CLEANUP_DIRS:-} $wrapper_dir"

    build_electron_wrapper "$release_dir" "$wrapper_dir" || exit 1

    # Update state
    set_current_version "$VERSION"
    get_latest_wrapper_commit > "$WRAPPER_VERSION_FILE"

    # Verify
    verify_installation

    log_step "Setup Complete"
    log_info "Codex Desktop v$VERSION installed to $INSTALL_DIR"
    log_info "Launch with: $INSTALL_DIR/codex-desktop"
    log_info "Or start from the XFCE application menu"
}

main "$@"
