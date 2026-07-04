#!/usr/bin/env bats
# =============================================================================
# CoLinux — Syntax & shebang suite
# =============================================================================
# Verifies every shell script (scripts/*.sh + all codex-* wrappers across
# editions) parses cleanly and declares a valid shebang. These are the first
# line of defense against broken commits and cross-edition drift.
# =============================================================================

load "../lib/helpers"

# Helper: collect failures across a file set, fail once with the full list.
_check_all() {
    local check_fn="$1"
    local label="$2"
    local file failures=""
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        if ! "$check_fn" "$file"; then
            failures="${failures}\n  ${label}: ${file}"
        fi
    done < <(colinux_list_all_shell)
    if [ -n "$failures" ]; then
        colinux_fail "Failures:${failures}"
    fi
}

# -----------------------------------------------------------------------------
# bash -n syntax validation
# -----------------------------------------------------------------------------

_syntax_ok() {
    bash -n "$1" 2>/dev/null
}

@test "all shell scripts pass 'bash -n' syntax check" {
    _check_all _syntax_ok "SYNTAX ERROR"
}

# -----------------------------------------------------------------------------
# Shebang validation
# -----------------------------------------------------------------------------

_has_shell_shebang() {
    local file="$1" first
    first="$(head -n1 "$file" 2>/dev/null)"
    case "$first" in
        *"/bin/bash"*|*"/bin/sh"*|*"/bin/ash"*|*"env bash"*|*"env sh"*|*"env ash"*) return 0 ;;
        *) return 1 ;;
    esac
}

@test "all scripts declare a shell shebang on line 1" {
    _has_shell_shebang_line1() {
        local first
        first="$(head -n1 "$1" 2>/dev/null)"
        # Shebang must be the very first two bytes.
        [ "${first:0:2}" = "#!" ] && _has_shell_shebang "$1"
    }
    _check_all _has_shell_shebang_line1 "MISSING/INVALID SHEBANG"
}

@test "no script uses '/bin/sh' while relying on bash-only features" {
    # Scripts declaring bash (via /bin/bash OR 'env bash') may use bashisms.
    # Scripts declaring /bin/sh or /bin/ash must not use clear bash-only
    # constructs that dash/ash reject: [[ ]], `function` keyword, declare -A.
    local file offenders=""
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        local first
        first="$(head -n1 "$file" 2>/dev/null)"
        case "$first" in
            *"/bin/bash"*|*"env bash"*) continue ;;   # bash script — bashisms OK
        esac
        if grep -nEq '\[\[ |(^|[[:space:]])function[[:space:]]|declare -[aA]|mapfile|readarray' "$file" 2>/dev/null; then
            offenders="${offenders}\n  BASHISM IN sh SCRIPT: ${file}"
        fi
    done < <(colinux_list_all_shell)
    if [ -n "$offenders" ]; then
        colinux_fail "Bash-only constructs in /bin/sh scripts:${offenders}"
    fi
}
