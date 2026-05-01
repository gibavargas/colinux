#!/bin/sh
# =============================================================================
# CoLinux Compat — codex user profile (~/.profile)
# =============================================================================

# ── Environment ──────────────────────────────────────────────────────────────
export CODEX_HOME="/home/codex"
export CODEX_WORKSPACE="/workspace"
export CODEX_PERSIST="/persist"
export CODEX_CONFIG="$CODEX_PERSIST/config"
export CODEX_LOGS="$CODEX_PERSIST/logs"
export CODEX_EDITION="compat"

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
if [ -t 0 ] && command -v codex-shell-compat >/dev/null 2>&1; then
    if [ "${CODEX_SKIP_SHELL:-0}" != "1" ]; then
        exec codex-shell-compat
    fi
fi
