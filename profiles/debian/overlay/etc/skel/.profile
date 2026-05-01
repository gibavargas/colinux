# /etc/skel/.profile — CoLinux Desktop user skeleton
# Copied to /home/codex on first user creation

# CoLinux additions
export PATH="$PATH:/usr/local/bin"
export EDITOR="${EDITOR:-vim}"
export VISUAL="${VISUAL:-vim}"

# Codex Desktop
export CODEX_HOME="/opt/codex-desktop"
export CODEX_CONFIG_DIR="/persist/config/codex"

# If running bash, include .bashrc if it exists
if [ -n "$BASH_VERSION" ]; then
    if [ -f "$HOME/.bashrc" ]; then
        . "$HOME/.bashrc"
    fi
fi

# XDG directories
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

# Codex CLI shorthand
codex() {
    if [ -x /usr/local/bin/codex ]; then
        /usr/local/bin/codex "$@"
    elif [ -x /opt/codex-desktop/codex ]; then
        /opt/codex-desktop/codex "$@"
    else
        echo "Codex not found. Run: codexctl setup" >&2
        return 1
    fi
}
