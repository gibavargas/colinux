#!/bin/bash
# =============================================================================
# CoLinux test helpers — shared functions for bats unit tests.
# =============================================================================
# Sourced by bats via:  load "../lib/helpers"
#
# Provides discovery helpers that enumerate the scripts and codex-* wrappers
# under test, so new files are covered automatically without editing tests.
# =============================================================================

# Resolve project root regardless of where bats is invoked from.
COLINUX_ROOT="${COLINUX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)}"
export COLINUX_ROOT

# Colors for human-readable output (used by runners, not bats).
if [ -t 1 ]; then
    COLINUX_RED='\033[0;31m'
    COLINUX_GREEN='\033[0;32m'
    COLINUX_YELLOW='\033[1;33m'
    COLINUX_NC='\033[0m'
else
    COLINUX_RED=''; COLINUX_GREEN=''; COLINUX_YELLOW=''; COLINUX_NC=''
fi

# -----------------------------------------------------------------------------
# Discovery helpers
# -----------------------------------------------------------------------------

# Print all scripts/*.sh (the lint-gate set), one per line, sorted.
colinux_list_scripts() {
    find "$COLINUX_ROOT/scripts" -maxdepth 1 -name '*.sh' -type f 2>/dev/null | sort
}

# Print all codex-* shell wrapper scripts across every edition — including
# installer/ and disk/ copies — so cross-edition drift is caught automatically.
# Only files whose first line is a shell shebang are included (excludes configs,
# systemd units, pkla, sudoers, desktop entries).
colinux_list_wrappers() {
    python3 - "$COLINUX_ROOT" <<'PY'
import os, sys
root = sys.argv[1]
out = []
for dirpath, _dirs, files in os.walk(root):
    if os.sep + '.git' + os.sep in dirpath + os.sep or dirpath.startswith(os.path.join(root, 'tests')):
        continue
    for fn in files:
        if not fn.startswith('codex-'):
            continue
        path = os.path.join(dirpath, fn)
        try:
            with open(path, 'rb') as fh:
                first = fh.readline().decode('utf-8', 'ignore').strip()
        except OSError:
            continue
        if first.startswith('#!') and ('bin/bash' in first or 'bin/sh' in first or 'bin/ash' in first):
            out.append(path)
for p in sorted(out):
    print(p)
PY
}

# Print every shell script that should be syntax-checked: scripts/*.sh plus all
# discovered wrappers. Used by the bats syntax suite.
colinux_list_all_shell() {
    colinux_list_scripts
    colinux_list_wrappers
}

# -----------------------------------------------------------------------------
# Assertions
# -----------------------------------------------------------------------------

# Fail the current bats test with a multi-line message. bats exposes `fail` via
# bats-assert, but this works without any external helper library.
colinux_fail() {
    echo "# FAIL: $*" >&3
    false
}
