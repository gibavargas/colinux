# CodexOS Compat — codex user bashrc

# ── Aliases (same as Alpine edition) ──────────────────────────────────────────
alias ci='codex-disk-inventory'
alias cm='codex-mount-ro'
alias cmw='codex-mount-rw'
alias cn='codex-network'
alias cu='codex-update'
alias cb='codex-backup'
alias cl='codex-logs'
alias ct='codexctl'

# ── History ───────────────────────────────────────────────────────────────────
export HISTSIZE=5000
export HISTFILE="${HOME:-/home/codex}/.codex_history"
export HISTCONTROL="ignoredups:ignorespace"

# ── Pager & Editor ────────────────────────────────────────────────────────────
export PAGER="${PAGER:-less}"
export LESS="${LESS:-FRSX}"
export EDITOR="${EDITOR:-nano}"
export VISUAL="${VISUAL:-nano}"
