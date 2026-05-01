#!/bin/bash
# /home/codex/.bashrc — CoLinux Lite GUI Edition
# Sources workspace context (AGENTS.md), sets up environment for GUI sessions.

# ── Prevent re-sourcing in non-interactive shells ────────────────────────────
[[ $- != *i* ]] && return

# ── Source workspace context ─────────────────────────────────────────────────
if [[ -f /workspace/AGENTS.md ]]; then
    export CODEX_AGENTS_CONTEXT="/workspace/AGENTS.md"
fi

# ── Environment setup ────────────────────────────────────────────────────────
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export EDITOR="${EDITOR:-vi}"
export VISUAL="${VISUAL:-vi}"
export TERM="${TERM:-xterm-256color}"
export LANG="en_US.UTF-8"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

# Add /workspace/bin to PATH
if [[ -d /workspace/bin ]]; then
    export PATH="/workspace/bin:${PATH}"
fi

# ── Wayland environment (set when running inside cage/sway) ──────────────────
if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
fi

# ── Persist user profile customizations (safe parse: only export VAR=value) ─
if [[ -f /persist/profile ]]; then
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*= ]]; then
            eval "$line"
        fi
    done < /persist/profile
fi

# ── Prompt ───────────────────────────────────────────────────────────────────
if [[ "$(id -u)" -eq 0 ]]; then
    export PS1='\[\e[1;31m\]codex(root)\[\e[0m\]:\w\$ '
else
    export PS1='\[\e[1;32m\]codex\[\e[0m\]:\w\$ '
fi

# ── Aliases ──────────────────────────────────────────────────────────────────
alias ll='ls -laF'
alias la='ls -A'
alias l='ls -CF'
alias cls='clear'
alias logs='tail -f /persist/logs/gui-session.log'

# ── Shell functions ──────────────────────────────────────────────────────────
codex-restart-gui() {
    echo "Restarting GUI session..."
    doas rc-service codex-gui restart 2>/dev/null || sudo rc-service codex-gui restart 2>/dev/null
}

codex-fallback-tty() {
    echo "Falling back to TTY mode..."
    doas rc-service codex-gui stop 2>/dev/null || sudo rc-service codex-gui stop 2>/dev/null
    exec /usr/local/bin/codex-shell
}

codex-screenshot() {
    local out="/persist/logs/screenshot-$(date +%Y%m%d-%H%M%S).png"
    grim "$out" 2>/dev/null && echo "Screenshot saved: $out" || echo "grim failed"
}
