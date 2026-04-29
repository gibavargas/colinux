#!/usr/bin/env bash
# CodexOS Desktop setup is intentionally disabled for the production Lite
# baseline. The MVP ships Codex CLI, not the Electron desktop wrapper.
set -euo pipefail

echo "Codex Desktop setup is disabled in CodexOS Lite." >&2
echo "Use the Alpine Codex CLI appliance profile for production builds." >&2
exit 1
