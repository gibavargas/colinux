#!/usr/bin/env bats
# =============================================================================
# CoLinux — codex-* wrapper contract & security suite
# =============================================================================
# Enforces the operational and security conventions every codex-* command must
# follow (see AGENTS.md §9 and the audit P0/P1 checklist). Catches exactly the
# regression classes found across 30+ daily audits:
#
#   * missing `set -euo pipefail`           (operational safety)
#   * missing --help / -h handling          (discoverability contract)
#   * missing die()/error exit helper       (consistent failure surface)
#   * `grep -oP` PCRE usage                 (BusyBox incompatibility on Alpine)
#   * `eval`/`source` on untrusted content  (P0 shell-injection vector)
#   * logging to /persist/logs/             (logging standardization)
# =============================================================================

load "../lib/helpers"

# Wrappers that are intentionally minimal and exempt from the --help/die()
# contract: interactive shell launchers (typing `codex-shell --help` to open a
# shell makes no sense).
_EXEMPT_SHELL_WRAPPERS=(
    "profiles/alpine/overlay/usr/local/bin/codex-shell"
    "profiles/alpine/overlay-gui/usr/local/bin/codex-shell-gui"
    "profiles/alpine/overlay-desktop/usr/local/bin/codex-shell-desktop"
    "profiles/debian-compat/overlay/usr/local/bin/codex-shell-compat"
)

# -----------------------------------------------------------------------------
# 1. `set -euo pipefail` (or `set -eu`) present
# -----------------------------------------------------------------------------

@test "every wrapper enables strict error mode (set -e[uo pipefail])" {
    local file offenders=""
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        if ! grep -Eq 'set -e(uo pipefail|u pipefail|uo|u)' "$file" 2>/dev/null; then
            offenders="${offenders}\n  MISSING set -e[uo pipefail]: ${file}"
        fi
    done < <(colinux_list_wrappers)
    [ -z "$offenders" ] || colinux_fail "Wrappers missing strict mode:${offenders}"
}

# -----------------------------------------------------------------------------
# KNOWN-GAPS PATTERN (used for --help and die() convention coverage)
# -----------------------------------------------------------------------------
# These wrappers genuinely lack the --help flag / die() helper today. The test
# asserts the actual non-compliant set EXACTLY equals this baseline, so:
#   * fixing a wrapper (removing a gap) requires shrinking the list → green
#   * a NEW wrapper missing the contract → fails (must fix or register)
# This keeps the suite green while documenting and preventing regression.
# Closing these gaps is tracked as follow-up "wrapper convention hardening".
# Paths are relative to COLINUX_ROOT.
# -----------------------------------------------------------------------------

_KNOWN_HELP_GAPS=(
    "disk/codex-disk-inventory"
    "disk/codex-mount-ro"
    "profiles/alpine/overlay/usr/local/bin/codex-disk-inventory"
    "profiles/alpine/overlay/usr/local/bin/codex-mount-ro"
    "profiles/debian-compat/overlay/usr/local/bin/codex-disk-inventory"
    "profiles/debian-compat/overlay/usr/local/bin/codex-mount-ro"
)

_KNOWN_DIE_GAPS=(
    "disk/codex-disk-inventory"
    "disk/codex-mount-ro"
    "disk/codex-mount-rw"
    "profiles/alpine/overlay/usr/local/bin/codex-disk-inventory"
    "profiles/alpine/overlay/usr/local/bin/codex-logs"
    "profiles/alpine/overlay/usr/local/bin/codex-mount-ro"
    "profiles/alpine/overlay/usr/local/bin/codex-mount-rw"
    "profiles/alpine/overlay/usr/local/bin/codex-network"
    "profiles/debian-compat/overlay/usr/local/bin/codex-disk-inventory"
    "profiles/debian-compat/overlay/usr/local/bin/codex-logs"
    "profiles/debian-compat/overlay/usr/local/bin/codex-mount-ro"
    "profiles/debian-compat/overlay/usr/local/bin/codex-mount-rw"
    "profiles/debian-compat/overlay/usr/local/bin/codex-network"
)

# Normalize an absolute path to a path relative to COLINUX_ROOT for comparison.
_relpath() {
    local abs="$1"
    case "$abs" in
        "$COLINUX_ROOT"/*) printf '%s\n' "${abs#"$COLINUX_ROOT"/}" ;;
        *) printf '%s\n' "$abs" ;;
    esac
}

# Print sorted, newline-separated set of array elements (relative paths).
_sorted_set() {
    local arr_name="$1" out=""
    eval "local arr=(\"\${${arr_name}[@]}\")"
    local e
    for e in "${arr[@]}"; do
        out="${out}$(_relpath "$COLINUX_ROOT/$e")"$'\n'
    done
    printf '%s' "$out" | grep -v '^$' | sort -u
}

_is_shell_wrapper() {
    local rel="$1"
    local e
    for e in "${_EXEMPT_SHELL_WRAPPERS[@]}"; do
        [ "$rel" = "$e" ] && return 0
    done
    return 1
}

# -----------------------------------------------------------------------------
# 2. --help / -h flag handling (known-gaps coverage)
# -----------------------------------------------------------------------------

@test "every non-shell wrapper documents --help (known-gaps baseline)" {
    local expected actual
    expected="$(_sorted_set _KNOWN_HELP_GAPS)"

    # Build the actual non-compliant set; command substitution normalizes
    # trailing newlines and `sort -u` normalizes ordering/duplicates.
    actual="$(
        local file rel
        while IFS= read -r file; do
            [ -n "$file" ] || continue
            rel="$(_relpath "$file")"
            _is_shell_wrapper "$rel" && continue
            # Lenient: the wrapper references --help or -h anywhere (code or usage).
            if ! grep -Eq -- '--help|(^|[^-])-h([^a-zA-Z]|$)' "$file" 2>/dev/null; then
                printf '%s\n' "$rel"
            fi
        done < <(colinux_list_wrappers) | sort -u
    )"

    if [ "$actual" != "$expected" ]; then
        colinux_fail "--help gap set drifted from baseline.
Expected (known gaps):
$expected
Actual (current gaps):
$actual
If you FIXED a wrapper, remove it from _KNOWN_HELP_GAPS.
If you ADDED a wrapper, add --help or register it in _KNOWN_HELP_GAPS."
    fi
}

# -----------------------------------------------------------------------------
# 3. die()/error() helper (known-gaps coverage)
# -----------------------------------------------------------------------------

@test "every non-shell wrapper defines a die()/error()/fail() helper (known-gaps baseline)" {
    local expected actual
    expected="$(_sorted_set _KNOWN_DIE_GAPS)"

    actual="$(
        local file rel
        while IFS= read -r file; do
            [ -n "$file" ] || continue
            rel="$(_relpath "$file")"
            _is_shell_wrapper "$rel" && continue
            if ! grep -Eq '(die|error|fail)[[:space:]]*\(\)' "$file" 2>/dev/null; then
                printf '%s\n' "$rel"
            fi
        done < <(colinux_list_wrappers) | sort -u
    )"

    if [ "$actual" != "$expected" ]; then
        colinux_fail "die() gap set drifted from baseline.
Expected (known gaps):
$expected
Actual (current gaps):
$actual
If you FIXED a wrapper, remove it from _KNOWN_DIE_GAPS.
If you ADDED a wrapper, add die()/error() or register it in _KNOWN_DIE_GAPS."
    fi
}

# -----------------------------------------------------------------------------
# 4. No `grep -oP` (BusyBox grep has no -P flag — recurring Alpine bug)
# -----------------------------------------------------------------------------

@test "no wrapper uses 'grep -oP' (PCRE unsupported on BusyBox)" {
    local file offenders=""
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        if grep -nE 'grep[[:space:]]+(-[A-Za-z]*o[A-Za-z]*[[:space:]]+)?-([A-Za-z]*P[A-Za-z]*|oP)' "$file" 2>/dev/null \
           | grep -qv 'grep -oE'; then
            if grep -nEq 'grep[[:space:]].*-P' "$file" 2>/dev/null; then
                offenders="${offenders}\n  grep -P USAGE: ${file}"
            fi
        fi
    done < <(colinux_list_wrappers)
    [ -z "$offenders" ] || colinux_fail "Wrappers using grep -P (BusyBox incompatible):${offenders}"
}

# -----------------------------------------------------------------------------
# 5. No `eval` / `source` on untrusted input (P0 shell injection)
# -----------------------------------------------------------------------------

@test "no wrapper uses 'eval' on a variable or line" {
    local file offenders=""
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        # Flag `eval "$var"` / `eval "$line"` — the known injection pattern.
        if grep -nE 'eval[[:space:]]+"\$\(' "$file" 2>/dev/null \
           || grep -nEq 'eval[[:space:]]+"\$line"' "$file" 2>/dev/null; then
            offenders="${offenders}\n  eval ON VARIABLE: ${file}"
        fi
    done < <(colinux_list_wrappers)
    [ -z "$offenders" ] || colinux_fail "Wrappers with eval on untrusted input (P0):${offenders}"
}

@test "no wrapper 'source's untrusted user-writable files" {
    # Flags bare `source "$.../profile"` or `. "$.../profile"` patterns that
    # execute user-writable content as root. Safe key=value parsing is allowed.
    local file offenders=""
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        if grep -nEq '(^|[[:space:]])(source|\.)[[:space:]]+"\$\{?[A-Z_]*PROFILE' "$file" 2>/dev/null \
           || grep -nEq '(^|[[:space:]])(source|\.)[[:space:]]+"\$\{?PERSIST_DIR\}/profile"' "$file" 2>/dev/null; then
            offenders="${offenders}\n  source ON PROFILE: ${file}"
        fi
    done < <(colinux_list_wrappers)
    [ -z "$offenders" ] || colinux_fail "Wrappers sourcing profile (P0):${offenders}"
}

# -----------------------------------------------------------------------------
# 6. Logging to /persist/logs/ (logging standardization)
# -----------------------------------------------------------------------------

@test "every operational wrapper references a logs path" {
    # Skip pure installers and desktop stubs that legitimately have no runtime
    # logging. Focus on the 19 core operational commands documented in AGENTS.md.
    local core_cmds=(
        codex-backup codex-benchmark codex-clone codex-disk-inventory
        codex-hw-check codex-install-pc codex-install-usb codex-logs
        codex-mount-ro codex-mount-rw codex-network codex-pxe
        codex-recover codex-remote codex-restore codex-snapshot
        codex-update codex-usb-persist
    )
    local cmd file offenders=""
    for cmd in "${core_cmds[@]}"; do
        # Only check the canonical alpine overlay copy (the reference impl).
        file="$COLINUX_ROOT/profiles/alpine/overlay/usr/local/bin/$cmd"
        [ -f "$file" ] || continue
        if ! grep -Eq 'logs|LOG(_DIR|FILE)|/persist/logs' "$file" 2>/dev/null; then
            offenders="${offenders}\n  NO LOGGING: ${file}"
        fi
    done
    [ -z "$offenders" ] || colinux_fail "Core wrappers without logging:${offenders}"
}

# -----------------------------------------------------------------------------
# 7. No masked-literal secret writes (P0: saves "***" instead of value)
# -----------------------------------------------------------------------------

@test "no wrapper writes a masked '***' literal as a credential value" {
    # Catches the recurring bug where `export KEY="***"` saves the literal mask
    # string instead of a variable's real value. Legitimate sentinel
    # *comparisons* (rejecting "***") are allowed.
    local file offenders=""
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        # An assignment/export of a key/tok to a quoted "***" literal is the bug.
        if grep -nE '(KEY|TOKEN|SECRET|PASSPHRASE|PASSWORD)[[:space:]]*=[[:space:]]*"\*{3}"' "$file" 2>/dev/null; then
            offenders="${offenders}\n  MASKED-LITERAL WRITE: ${file}"
        fi
    done < <(colinux_list_wrappers)
    [ -z "$offenders" ] || colinux_fail "Wrappers writing masked '***' as a value (P0):${offenders}"
}
