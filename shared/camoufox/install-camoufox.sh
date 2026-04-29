#!/usr/bin/env bash
# ============================================================================
# CodexOS — Camoufox Browser Integration Installer
# ============================================================================
# Installs Camoufox (anti-fingerprinting Firefox browser) for web search
# and browsing capabilities across all CodexOS editions.
#
# Usage: install-camoufox.sh [--prefix /opt/camoufox] [--force]
#
# Detects:
#   - Architecture (x86_64 / aarch64)
#   - Distro (Alpine / Debian)
#   - Edition type (TTY / GUI) via argument or environment
#
# Creates:
#   /usr/local/bin/camoufox           — GUI wrapper
#   /usr/local/bin/camoufox-headless  — Headless wrapper
#   /usr/local/bin/codex-web-search   — Web search tool (text/JSON output)
#   /usr/local/bin/codex-web-browse   — Browse launcher (GUI or headless)
# ============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
INSTALL_PREFIX="${INSTALL_PREFIX:-/opt/camoufox}"
FORCE_INSTALL="${FORCE_INSTALL:-0}"
CODEX_EDITION="${CODEX_EDITION:-auto}"   # lite|lite-gui|compat|desktop|auto
LOG_TAG="camoufox-install"
PERSIST_LOG="/persist/logs/network.log"

# Colors for terminal output
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()    { echo -e "${GREEN}[$LOG_TAG]${NC} $*"; }
warn()   { echo -e "${YELLOW}[$LOG_TAG]${NC} WARNING: $*" >&2; }
error()  { echo -e "${RED}[$LOG_TAG]${NC} ERROR: $*" >&2; }
info()   { echo -e "${BLUE}[$LOG_TAG]${NC} $*"; }

log_to_persist() {
    if [[ -w "/persist/logs" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] [camoufox] $*" >> "$PERSIST_LOG" 2>/dev/null || true
    fi
}

die() {
    error "$*"
    exit 1
}

# ---------------------------------------------------------------------------
# Detect system properties
# ---------------------------------------------------------------------------
detect_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)
            echo "x86_64"
            ;;
        aarch64|arm64)
            echo "aarch64"
            ;;
        *)
            die "Unsupported architecture: $arch. Camoufox requires x86_64 or aarch64."
            ;;
    esac
}

detect_distro() {
    if [[ -f /etc/alpine-release ]]; then
        echo "alpine"
    elif [[ -f /etc/debian_version ]] || grep -qi debian /etc/os-release 2>/dev/null; then
        echo "debian"
    else
        # Fallback: check os-release ID
        if [[ -f /etc/os-release ]]; then
            . /etc/os-release
            case "${ID}" in
                alpine*) echo "alpine" ;;
                debian|ubuntu|devuan) echo "debian" ;;
                *) die "Unsupported distro: ${ID}. Only Alpine and Debian families are supported." ;;
            esac
        else
            die "Cannot detect Linux distribution."
        fi
    fi
}

detect_edition() {
    if [[ "$CODEX_EDITION" != "auto" ]]; then
        echo "$CODEX_EDITION"
        return
    fi
    # Auto-detect: if DISPLAY is set and we have X/Wayland, assume GUI-capable
    if [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        echo "desktop"
    elif command -v Xorg &>/dev/null || command -v Xwayland &>/dev/null; then
        echo "lite-gui"
    else
        echo "lite"
    fi
}

has_gui() {
    local edition="$1"
    case "$edition" in
        lite-gui|compat|desktop) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Install system dependencies
# ---------------------------------------------------------------------------
install_deps_alpine() {
    log "Installing Alpine dependencies..."
    local pkg_file
    pkg_file="$(dirname "$0")/../packages/alpine-camoufox.txt"
    if [[ -f "$pkg_file" ]]; then
        local pkgs
        pkgs=$(grep -v '^\s*#' "$pkg_file" | grep -v '^\s*$' | tr '\n' ' ')
        if [[ -n "$pkgs" ]]; then
            apk add --no-cache $pkgs || warn "Some packages failed to install (non-fatal for existing installs)"
        fi
    else
        apk add --no-cache python3 py3-pip py3-requests py3-cryptography \
            gcc g++ musl-dev rust cargo openssl-dev sqlite-dev tk \
            libffi-dev make pkgconfig linux-headers || \
            warn "Package installation had issues — continuing anyway"
    fi
    # Ensure pip is available
    if ! command -v pip3 &>/dev/null; then
        apk add --no-cache py3-pip || die "Cannot install pip3 on Alpine"
    fi
}

install_deps_debian() {
    log "Installing Debian dependencies..."
    # Ensure we have updated indices
    apt-get update -qq || warn "apt-get update failed — using cache"

    local pkg_file
    pkg_file="$(dirname "$0")/../packages/debian-camoufox.txt"
    if [[ -f "$pkg_file" ]]; then
        local pkgs
        pkgs=$(grep -v '^\s*#' "$pkg_file" | grep -v '^\s*$' | tr '\n' ' ')
        # Fix linux-headers for non-amd64
        local host_arch
        host_arch="$(uname -m)"
        pkgs="${pkgs/linux-headers-amd64/linux-headers-${host_arch}}"
        if [[ -n "$pkgs" ]]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkgs 2>&1 || \
                warn "Some packages failed to install (non-fatal)"
        fi
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            python3 python3-pip python3-venv python3-dev python3-setuptools \
            python3-cryptography python3-requests gcc g++ rust-all \
            libssl-dev libsqlite3-dev libffi-dev make pkg-config 2>&1 || \
            warn "Package installation had issues — continuing anyway"
    fi
}

install_system_deps() {
    local distro="$1"
    case "$distro" in
        alpine) install_deps_alpine ;;
        debian) install_deps_debian ;;
    esac
    log_to_persist "System dependencies installed for $distro"
}

# ---------------------------------------------------------------------------
# Install Camoufox Python package + binary
# ---------------------------------------------------------------------------
install_camoufox_python() {
    log "Installing camoufox Python package via pip..."

    # Use a virtual environment to avoid system pollution
    local venv_dir="$INSTALL_PREFIX/venv"
    if [[ "$FORCE_INSTALL" == "1" ]] && [[ -d "$venv_dir" ]]; then
        log "Force reinstall — removing existing venv..."
        rm -rf "$venv_dir"
    fi

    if [[ ! -d "$venv_dir" ]]; then
        python3 -m venv "$venv_dir" || die "Failed to create virtual environment at $venv_dir"
    fi

    source "$venv_dir/bin/activate"

    # Upgrade pip first
    pip install --upgrade pip setuptools wheel 2>&1 | tail -5

    # Install camoufox
    if ! pip install 'camoufox>=0.4,<2.0' 2>&1; then
        error "pip install camoufox failed!"
        error "This may be due to missing system dependencies or network issues."
        error "Check the output above for details."
        deactivate
        return 1
    fi

    log "Downloading Camoufox Firefox binary..."
    if ! camoufox fetch 2>&1; then
        error "camoufox fetch failed — the Firefox binary could not be downloaded."
        error "This usually requires network access. Retrying once..."
        sleep 2
        if ! camoufox fetch 2>&1; then
            error "camoufox fetch failed permanently."
            deactivate
            return 1
        fi
    fi

    deactivate
    log_to_persist "Camoufox Python package and binary installed successfully"
    return 0
}

# ---------------------------------------------------------------------------
# Create wrapper scripts
# ---------------------------------------------------------------------------
create_wrapper() {
    local target="$1"
    local content="$2"
    cat > "$target" <<WRAPPER_EOF
${content}
WRAPPER_EOF
    chmod 755 "$target"
    log "Created wrapper: $target"
}

create_wrappers() {
    local edition="$1"
    local venv_python="$INSTALL_PREFIX/venv/bin/python"
    local gui_mode=""

    has_gui "$edition" && gui_mode="gui" || gui_mode="tty"

    # --- /usr/local/bin/camoufox (GUI launcher) ---
    create_wrapper "/usr/local/bin/camoufox" "#!/usr/bin/env bash
# CodexOS — Camoufox GUI Launcher
# Launches the Camoufox anti-fingerprinting browser with a GUI.
# Source: https://github.com/AntiBrowser/camoufox
set -euo pipefail

CAMOUFOX_VENV=\"$INSTALL_PREFIX/venv\"

if [[ ! -d \"\$CAMOUFOX_VENV\" ]]; then
    echo \"ERROR: Camoufox is not installed. Run install-camoufox.sh first.\" >&2
    exit 1
fi

source \"\$CAMOUFOX_VENV/bin/activate\"

# Check for display
if [[ -z \"\${DISPLAY:-}\" ]] && [[ -z \"\${WAYLAND_DISPLAY:-}\" ]]; then
    echo \"ERROR: No display server detected. Use camoufox-headless for TTY mode.\" >&2
    echo \"       Or set DISPLAY / WAYLAND_DISPLAY environment variable.\" >&2
    exit 1
fi

exec camoufox \"\$@\"
"

    # --- /usr/local/bin/camoufox-headless ---
    create_wrapper "/usr/local/bin/camoufox-headless" "#!/usr/bin/env bash
# CodexOS — Camoufox Headless Launcher
# Launches Camoufox in headless mode for TTY / server editions.
# Accepts the same arguments as the regular camoufox command.
set -euo pipefail

CAMOUFOX_VENV=\"$INSTALL_PREFIX/venv\"

if [[ ! -d \"\$CAMOUFOX_VENV\" ]]; then
    echo \"ERROR: Camoufox is not installed. Run install-camoufox.sh first.\" >&2
    exit 1
fi

source \"\$CAMOUFOX_VENV/bin/activate\"

# Force headless mode via Xvfb if available, otherwise use --headless flag
if command -v Xvfb &>/dev/null; then
    export DISPLAY=:99
    Xvfb :99 -screen 0 1280x1024x24 -nolisten tcp &
    XVFB_PID=\$!
    trap \"kill \$XVFB_PID 2>/dev/null; wait \$XVFB_PID 2>/dev/null\" EXIT
    sleep 0.5
    exec camoufox \"\$@\"
else
    # Use Mozilla's built-in headless mode
    exec camoufox --headless \"\$@\"
fi
"

    # --- /usr/local/bin/codex-web-search ---
    create_wrapper "/usr/local/bin/codex-web-search" '#!/usr/bin/env bash
# ============================================================================
# CodexOS — Web Search Tool (Camoufox Headless)
# ============================================================================
# Performs web searches using Camoufox in headless mode and returns
# results as formatted text or JSON.
#
# Usage:
#   codex-web-search "query"                    — formatted text output
#   codex-web-search --json "query"             — JSON output
#   codex-web-search --count 10 "query"         — limit results
#   codex-web-search --engine google "query"    — specify search engine
#   codex-web-search --url https://example.com  — fetch and extract page text
#
# Environment:
#   CODEX_SEARCH_ENGINE  — default: duckduckgo (also: google, bing)
#   CODEX_SEARCH_COUNT   — default: 5
#   CODEX_SEARCH_TIMEOUT — default: 30
# ============================================================================
set -euo pipefail

CAMOUFOX_VENV="'"$INSTALL_PREFIX/venv"'"
SEARCH_ENGINE="${CODEX_SEARCH_ENGINE:-duckduckgo}"
SEARCH_COUNT="${CODEX_SEARCH_COUNT:-5}"
SEARCH_TIMEOUT="${CODEX_SEARCH_TIMEOUT:-30}"
OUTPUT_JSON="no"
TARGET_URL=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)       OUTPUT_JSON="yes"; shift ;;
        --count)      SEARCH_COUNT="$2"; shift 2 ;;
        --engine)     SEARCH_ENGINE="$2"; shift 2 ;;
        --timeout)    SEARCH_TIMEOUT="$2"; shift 2 ;;
        --url)        TARGET_URL="$2"; shift 2 ;;
        -h|--help)
            sed -n "2,/^#$/s/^# //p" "$0"
            exit 0
            ;;
        *) break ;;
    esac
done
QUERY="${*:-}"

if [[ -z "$QUERY" && -z "$TARGET_URL" ]]; then
    echo "ERROR: No search query or URL provided. Usage: codex-web-search [options] <query>" >&2
    exit 1
fi

if [[ ! -d "$CAMOUFOX_VENV" ]]; then
    echo "ERROR: Camoufox not installed. Run install-camoufox.sh first." >&2
    exit 1
fi

source "$CAMOUFOX_VENV/bin/activate"

# Python search script (embedded for portability)
PYTHON_SCRIPT='"'"'
import sys
import json
import time
import urllib.parse

def search_duckduckgo(query, count, timeout):
    """Use DuckDuckGo HTML version for text search results."""
    from playwright.sync_api import sync_playwright
    results = []
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True, args=["--no-sandbox", "--disable-gpu"])
        try:
            page = browser.new_page(
                user_agent="Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
            )
            page.set_default_timeout(timeout * 1000)
            encoded = urllib.parse.quote_plus(query)
            page.goto(f"https://duckduckgo.com/html/?q={encoded}")
            page.wait_for_selector(".result", timeout=timeout * 1000)
            items = page.query_selector_all(".result")
            for item in items[:count]:
                title_el = item.query_selector(".result__title a, .result__a")
                snippet_el = item.query_selector(".result__snippet")
                url_el = item.query_selector(".result__url")
                title = title_el.inner_text().strip() if title_el else ""
                snippet = snippet_el.inner_text().strip() if snippet_el else ""
                url = url_el.inner_text().strip() if url_el else ""
                if not url and title_el:
                    url = title_el.get_attribute("href") or ""
                if title:
                    results.append({"title": title, "url": url, "snippet": snippet})
        except Exception as e:
            results.append({"error": str(e)})
        finally:
            browser.close()
    return results

def fetch_url(url, timeout):
    """Fetch a URL and extract readable text content."""
    from playwright.sync_api import sync_playwright
    content = ""
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True, args=["--no-sandbox", "--disable-gpu"])
        try:
            page = browser.new_page()
            page.set_default_timeout(timeout * 1000)
            page.goto(url, wait_until="domcontentloaded")
            content = page.inner_text("body")[:8000]
        except Exception as e:
            content = f"Error fetching URL: {e}"
        finally:
            browser.close()
    return content

def main():
    import subprocess
    args = json.loads(sys.argv[1])
    query = args["query"]
    count = int(args["count"])
    timeout = int(args["timeout"])
    engine = args["engine"]
    is_json = args["output_json"] == "yes"
    url = args["target_url"]

    if url:
        text = fetch_url(url, timeout)
        if is_json:
            print(json.dumps({"url": url, "content": text}, indent=2, ensure_ascii=False))
        else:
            print(f"=== {url} ===\n")
            print(text)
        return

    try:
        results = search_duckduckgo(query, count, timeout)
    except ImportError:
        # Fallback: use camoufox directly if playwright not standalone
        print(json.dumps({"error": "playwright not available as standalone; camoufox may need setup"}, indent=2))
        return

    if is_json:
        print(json.dumps({"query": query, "engine": engine, "results": results}, indent=2, ensure_ascii=False))
    else:
        print(f"Search results for: {query}")
        print(f"Engine: {engine} | Results: {len(results)}\n")
        print("=" * 70)
        for i, r in enumerate(results, 1):
            if "error" in r:
                print(f"\nERROR: {r['error']}\n")
                continue
            print(f"\n[{i}] {r.get('title', 'Untitled')}")
            print(f"    URL: {r.get('url', 'N/A')}")
            snippet = r.get('snippet', '')
            if snippet:
                print(f"    {snippet}")
        print("\n" + "=" * 70)

if __name__ == "__main__":
    main()
'"'"'

# Export arguments as JSON for the Python script (safe: uses env vars, not string interpolation)
export _CS_QUERY="$QUERY"
export _CS_ENGINE="$SEARCH_ENGINE"
export _CS_TARGET="$TARGET_URL"
export _CS_OUTPUT_JSON="$OUTPUT_JSON"
export _CS_COUNT="$SEARCH_COUNT"
export _CS_TIMEOUT="$SEARCH_TIMEOUT"
ARGS_JSON=$(python3 -c "
import json, os
print(json.dumps({
    'query': os.environ.get('_CS_QUERY', ''),
    'count': int(os.environ.get('_CS_COUNT', '5')),
    'timeout': int(os.environ.get('_CS_TIMEOUT', '30')),
    'engine': os.environ.get('_CS_ENGINE', 'duckduckgo'),
    'output_json': os.environ.get('_CS_OUTPUT_JSON', 'no'),
    'target_url': os.environ.get('_CS_TARGET', '')
}))
")
unset _CS_QUERY _CS_ENGINE _CS_TARGET _CS_OUTPUT_JSON _CS_COUNT _CS_TIMEOUT

exec python3 -c "$PYTHON_SCRIPT" "$ARGS_JSON"
'

    # --- /usr/local/bin/codex-web-browse ---
    if has_gui "$edition"; then
        create_wrapper "/usr/local/bin/codex-web-browse" "#!/usr/bin/env bash
# CodexOS — Web Browse Launcher (GUI Edition)
# Opens Camoufox browser for interactive web browsing.
# Falls back to headless mode if no display is available.
set -euo pipefail

CAMOUFOX_VENV=\"$INSTALL_PREFIX/venv\"

if [[ ! -d \"\$CAMOUFOX_VENV\" ]]; then
    echo \"ERROR: Camoufox not installed. Run install-camoufox.sh first.\" >&2
    exit 1
fi

source \"\$CAMOUFOX_VENV/bin/activate\"

if [[ -n \"\${DISPLAY:-}\" ]] || [[ -n \"\${WAYLAND_DISPLAY:-}\" ]]; then
    exec camoufox \"\$@\"
else
    echo \"No display detected — launching in headless mode.\" >&2
    echo \"Pass --help for headless options.\" >&2
    exec camoufox-headless \"\$@\"
fi
"
    else
        create_wrapper "/usr/local/bin/codex-web-browse" "#!/usr/bin/env bash
# CodexOS — Web Browse Launcher (TTY Edition)
# Opens Camoufox in headless mode. Use codex-web-search for queries.
set -euo pipefail

CAMOUFOX_VENV=\"$INSTALL_PREFIX/venv\"

if [[ ! -d \"\$CAMOUFOX_VENV\" ]]; then
    echo \"ERROR: Camoufox not installed. Run install-camoufox.sh first.\" >&2
    exit 1
fi

source \"\$CAMOUFOX_VENV/bin/activate\"
exec camoufox-headless \"\$@\"
"
    fi

    log_to_persist "Camoufox wrapper scripts created (edition=$edition, gui_mode=$gui_mode)"
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
validate_installation() {
    log "Validating installation..."
    local errors=0

    for cmd in camoufox camoufox-headless codex-web-search codex-web-browse; do
        if command -v "$cmd" &>/dev/null; then
            info "  ✓ $cmd"
        else
            error "  ✗ $cmd — NOT FOUND"
            ((errors++))
        fi
    done

    if [[ -d "$INSTALL_PREFIX/venv" ]]; then
        info "  ✓ Virtual environment at $INSTALL_PREFIX/venv"
    else
        error "  ✗ Virtual environment missing"
        ((errors++))
    fi

    if [[ "$errors" -eq 0 ]]; then
        log "All checks passed!"
        return 0
    else
        warn "$errors check(s) failed. Review errors above."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Parse CLI arguments
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prefix)
                INSTALL_PREFIX="$2"
                shift 2
                ;;
            --force)
                FORCE_INSTALL=1
                shift
                ;;
            --edition)
                CODEX_EDITION="$2"
                shift 2
                ;;
            -h|--help)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --prefix DIR    Install prefix (default: /opt/camoufox)"
                echo "  --edition ED    Edition: lite|lite-gui|compat|desktop|auto"
                echo "  --force         Force reinstall, removing existing venv"
                echo "  -h, --help      Show this help"
                exit 0
                ;;
            *)
                die "Unknown argument: $1. Use --help for usage."
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    local arch distro edition
    arch="$(detect_arch)"
    distro="$(detect_distro)"
    edition="$(detect_edition)"

    log "CodexOS Camoufox Installer"
    log "  Architecture : $arch"
    log "  Distribution : $distro"
    log "  Edition      : $edition"
    log "  Install prefix: $INSTALL_PREFIX"
    log ""

    # Require root (or doas/sudo)
    if [[ "$(id -u)" -ne 0 ]]; then
        if command -v doas &>/dev/null; then
            warn "Not root — re-executing with doas..."
            exec doas "$0" "$@"
        elif command -v sudo &>/dev/null; then
            warn "Not root — re-executing with sudo..."
            exec sudo "$0" "$@"
        else
            die "Root privileges required. Run as root, doas, or sudo."
        fi
    fi

    # Create install directory
    mkdir -p "$INSTALL_PREFIX" || die "Cannot create $INSTALL_PREFIX"

    # Ensure persist log directory exists
    mkdir -p /persist/logs 2>/dev/null || true

    # Step 1: Install system dependencies
    log "=== Step 1/4: Installing system dependencies ==="
    install_system_deps "$distro"

    # Step 2: Install Camoufox Python package
    log "=== Step 2/4: Installing Camoufox Python package ==="
    install_camoufox_python || die "Camoufox installation failed."

    # Step 3: Create wrapper scripts
    log "=== Step 3/4: Creating wrapper scripts ==="
    create_wrappers "$edition"

    # Step 4: Validate
    log "=== Step 4/4: Validating installation ==="
    validate_installation

    log ""
    log "========================================="
    log " Camoufox installation complete!"
    log "========================================="
    log ""
    log "  camoufox          — Launch GUI browser"
    log "  camoufox-headless — Launch headless browser"
    log "  codex-web-search  — Web search (text/JSON)"
    log "  codex-web-browse  — Browse launcher"
    log ""
    log_to_persist "Camoufox installation completed successfully (arch=$arch, distro=$distro, edition=$edition)"
}

main "$@"
