# CodexOS Desktop Guide

The Codex Desktop/Electron edition is intentionally disabled in the CodexOS Lite production baseline.

The supported production path is:

```bash
codexos-lite
Alpine Linux
Codex CLI standalone musl binary
TTY/tmux control surface
encrypted persistence
safe disk wrappers
```

Desktop setup scripts in the Debian profile now fail closed instead of downloading or wrapping desktop artifacts. Keep this guide as a placeholder for a future GUI terminal edition based on Cage/Sway, not as MVP deployment documentation.
