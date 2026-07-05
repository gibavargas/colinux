#!/usr/bin/env bats
# =============================================================================
# CoLinux — build reproducibility contract suite
# =============================================================================
# Verifies scripts/build-alpine.sh implements the v0.3 "Build reproducibility"
# deliverable: pinned Alpine repo snapshot support, APKINDEX state capture,
# artifact SHA-256 checksums, and a reproducibility manifest. These are STATIC
# contract checks — a full ISO build cannot run inside the unit suite.
#
# The reproducibility story these tests guard:
#   * same aports commit   (already pinned by APORTS_BRANCH tag)
#   * same Codex release    (resolved to an immutable tag + digest-verified)
#   * same package set      (ALPINE_REPO_SNAPSHOT + recorded APKINDEX checksums)
#   * verifiable artifacts  (SHA256SUMS + build-manifest.{txt,json} per build)
# =============================================================================

load "../lib/helpers"

BUILD_SCRIPT="$COLINUX_ROOT/scripts/build-alpine.sh"

@test "build-alpine.sh exists and is syntactically valid (bash -n)" {
    [ -f "$BUILD_SCRIPT" ]
    bash -n "$BUILD_SCRIPT"
}

@test "build-alpine.sh supports pinned Alpine repo snapshot" {
    # The ALPINE_REPO_SNAPSHOT env var pins repos to a frozen base URL.
    grep -q 'ALPINE_REPO_SNAPSHOT' "$BUILD_SCRIPT"
    grep -q 'repo_urls()' "$BUILD_SCRIPT"
}

@test "build-alpine.sh builds --repository flags from repo_urls()" {
    # mkimage must consume the resolved (snapshot-aware) repo list, not hardcode
    # the rolling v$ALPINE_RELEASE/* URLs.
    grep -q 'repo_args' "$BUILD_SCRIPT"
    grep -q 'repo_urls' "$BUILD_SCRIPT"
}

@test "build-alpine.sh captures Alpine repository APKINDEX checksums" {
    grep -q 'capture_repo_state()' "$BUILD_SCRIPT"
    grep -q 'APKINDEX.tar.gz' "$BUILD_SCRIPT"
}

@test "build-alpine.sh generates SHA-256 checksums for build artifacts" {
    grep -q 'generate_checksums()' "$BUILD_SCRIPT"
    grep -q 'sha256sum' "$BUILD_SCRIPT"
    grep -q 'SHA256SUMS' "$BUILD_SCRIPT"
}

@test "build-alpine.sh writes a reproducibility manifest (text + json)" {
    grep -q 'generate_build_manifest()' "$BUILD_SCRIPT"
    grep -q 'build-manifest.txt' "$BUILD_SCRIPT"
    grep -q 'build-manifest.json' "$BUILD_SCRIPT"
}

@test "build-alpine.sh manifest records aports commit and codex tag" {
    grep -q 'aports_commit' "$BUILD_SCRIPT"
    grep -q 'codex_tag' "$BUILD_SCRIPT"
}

@test "build-alpine.sh resolves codex tag to an immutable value for the manifest" {
    grep -q 'CODEX_RESOLVED_TAG' "$BUILD_SCRIPT"
}

@test "build-alpine.sh main() wires in the reproducibility steps" {
    grep -A25 '^main()' "$BUILD_SCRIPT" | grep -q 'capture_repo_state'
    grep -A25 '^main()' "$BUILD_SCRIPT" | grep -q 'generate_checksums'
    grep -A25 '^main()' "$BUILD_SCRIPT" | grep -q 'generate_build_manifest'
}
