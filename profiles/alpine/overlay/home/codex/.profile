#!/bin/sh
# =============================================================================
# CoLinux Lite — codex user profile (~/.profile)
# =============================================================================
# This file is sourced on login.  It prepares the environment and optionally
# launches the Codex shell (codex-shell) for a seamless CLI-first experience.
# =============================================================================

# ── Environment ──────────────────────────────────────────────────────────────
export CODEX_HOME="/home/codex"
export CODEX_WORKSPACE="/workspace"
export CODEX_PERSIST="/persist"
export CODEX_CONFIG="$CODEX_PERSIST/config"
export CODEX_LOGS="$CODEX_PERSIST/logs"

# ── Source system profile if available ────────────────────────────────────────
[ -f /etc/profile ] && . /etc/profile

# ── Personal PATH additions ──────────────────────────────────────────────────
[ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH"
export PATH

# ── Codex workspace ──────────────────────────────────────────────────────────
if [ -d "$CODEX_WORKSPACE" ]; then
    cd "$CODEX_WORKSPACE" 2>/dev/null
fi

# ── Auto-launch Codex shell ─────────────────────────────────────────────────
# Launch codex-shell if:
#   • We're on an interactive TTY
#   • codex-shell binary exists
#   • We haven't opted out via CODEX_SKIP_SHELL=1
if [ -t 0 ] && command -v codex-shell >/dev/null 2>&1; then
    if [ "${CODEX_SKIP_SHELL:-0}" != "1" ]; then
        exec codex-shell
    fi
fi
