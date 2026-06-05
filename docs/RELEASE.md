# Release Checklist — CoLinux Lite v0.2 (MVP)

This document is the authoritative release checklist for the **v0.2 usability MVP**.
It ties together MVP exit criteria, build, smoke tests, and artifact generation
with the **current** CoLinux naming and command surface.

For day-to-day build instructions see [`BUILD.md`](BUILD.md).
For the broader roadmap see [`../ROADMAP.md`](../ROADMAP.md).

---

## 1. MVP Exit Criteria

All four criteria **must** be satisfied before tagging v0.2. Each criterion is
backed by an automated or verifiable check.

| # | Criterion | How to verify | Status |
|---|-----------|---------------|--------|
| 1 | `colinux-lite` has a repeatable local smoke path from build artifact to QEMU boot + `codexctl status` | `./scripts/smoke-test.sh --all` exits 0 | ✅ |
| 2 | Installer / first-boot critical path has a dry-run or simulation test covering disk/ESP selection and first-boot hook execution — without touching real disks | `./scripts/smoke-test.sh --first-boot` exits 0 **and** `codex-install-pc --dry-run /dev/sim-nvme0n1` completes | ✅ |
| 3 | User-facing quickstart / release checklist is updated for the current repo name and commands | This document + `README.md` Quick Start use `colinux-*` naming; no `CodexOS` references in `docs/`, `README.md`, `AGENTS.md`, or shipped scripts | ✅ |
| 4 | No known open P0/P1 blockers in the sprint/audit notes for the above paths | Latest daily audit + sprint review report clean | ✅ |

### Criterion 1 — QEMU smoke path

```bash
# From a clean checkout on the release commit:
git clone https://github.com/gibavargas/colinux.git
cd colinux
git checkout <v0.2-tag>

./scripts/smoke-test.sh --all
# Stages exercised:
#   --docker      Build Docker image, validate `codexctl status`
#   --iso         Build (or auto-find) ISO and boot it in QEMU
#   --first-boot  Run `scripts/first-boot.sh --dry-run` inside the Docker image
```

Expected: all four stages report PASS, exit code 0.

### Criterion 2 — Installer + first-boot dry-run

```bash
# First-boot hook simulation (no real disk/network):
./scripts/smoke-test.sh --first-boot

# Installer dry-run (simulated device, no disk changes):
docker run --rm --entrypoint bash colinux-lite:smoke-test \
  -c '/usr/local/bin/codex-install-pc --dry-run /dev/sim-nvme0n1'
docker run --rm --entrypoint bash colinux-lite:smoke-test \
  -c '/usr/local/bin/codex-install-pc --dry-run --dual-boot /dev/sim-nvme0n1'
```

Expected: each command exits 0 and prints
`No disk changes were made. Re-run without --dry-run to install.`

### Criterion 3 — Naming alignment

```bash
# Should return zero matches across docs and shipped scripts:
grep -RIn 'CodexOS\|codexos' README.md AGENTS.md docs/ profiles/ scripts/ installer/ shared/ \
  --exclude-dir=.git || echo "OK: no stale naming"

# Quickstart commands verified to match actual CLI:
./scripts/smoke-test.sh --help     # lists --docker/--iso/--first-boot/--all
./scripts/release.sh --help        # lists --outdir/--version/--gpg-key/--arch
```

### Criterion 4 — No P0/P1 blockers

- Latest daily audit report: `clean` (see `references/daily-audit-*.md` in the
  Hermes skill archive, or the latest commit tagged `audit:`).
- Latest sprint review: `clean`.
- CI: all workflows green on the release commit
  (`gh run list --repo gibavargas/colinux --limit 10`).

---

## 2. Pre-release Checks

Run these on the release commit (`HEAD` after `git checkout <tag>`).

### 2.1 CI must be green

```bash
gh run list --repo gibavargas/colinux --limit 10
# Expect: most recent runs for Build Alpine ISO, Build Debian Desktop ISO,
# Build & Push Docker Image, Daily Issue & PR Review all show "success".
```

If any workflow is failing on the release commit, **do not tag**. Investigate
with `gh run view <id> --log-failed` and fix on `main` first.

### 2.2 Shell syntax + permission sweep

```bash
# Syntax check every shell script:
find . -name '*.sh' -not -path '*/.git/*' -not -path '*/dist/*' \
  -exec bash -n {} \; 2>&1 | tee /tmp/syntax.log
test ! -s /tmp/syntax.log && echo "OK: all scripts pass bash -n"

# Executable bit on overlay scripts (recurring bug source):
find profiles/*/overlay* -name '*.sh' -not -perm -111 -ls
# Expect: no output
```

### 2.3 Docker validation (all four editions)

The lite Dockerfile alone is not enough — name/path drift often only surfaces
in the other editions. Build all four:

```bash
docker build -t colinux-lite:test    -f Dockerfile         .
docker build -t colinux-gui:test     -f Dockerfile-gui     .
docker build -t colinux-compat:test  -f Dockerfile-compat  .
docker build -t colinux-desktop:test -f Dockerfile-desktop .
```

Each must complete without error. (Debian compat/desktop builds take longer;
they exercise live-build package lists and discovery paths.)

### 2.4 Smoke test (full pipeline)

```bash
./scripts/smoke-test.sh --all
```

### 2.5 Stale PR / issue hygiene

```bash
gh pr list --repo gibavargas/colinux --state open
gh issue list --repo gibavargas/colinux --state open
```

Close PRs whose commits are already in `main`:
`git fetch origin <branch> && git branch -a --contains <commit>`.

---

## 3. Build the Release Artifacts

### 3.1 Build the ISO

```bash
# Clean dist:
rm -rf dist/ && mkdir -p dist

# x86_64 (primary release target):
docker run --rm -v "$(pwd):/src" -e ARCH=x86_64 -e OUTDIR=/src/dist \
  alpine:3.21 sh -c "apk add --no-cache alpine-sdk apk-tools alpine-conf bash curl \
    ca-certificates git xorriso squashfs-tools mtools dosfstools grub grub-efi \
    efibootmgr e2fsprogs qemu-img openssl && cd /src && bash scripts/build-alpine.sh"

# aarch64 (secondary; no syslinux/isohybrid, EFI only):
docker run --rm -v "$(pwd):/src" -e ARCH=aarch64 -e OUTDIR=/src/dist \
  alpine:3.21 sh -c "apk add --no-cache alpine-sdk apk-tools alpine-conf bash curl \
    ca-certificates git xorriso squashfs-tools mtools dosfstools grub grub-efi \
    efibootmgr e2fsprogs qemu-img openssl && cd /src && bash scripts/build-alpine.sh"

ls -lh dist/
# Expect: colinux-lite-x86_64-*.iso  (and optionally *.raw.img / *.qcow2)
```

### 3.2 Generate checksums, manifest, and signatures

```bash
./scripts/release.sh --version 0.2.0 --arch x86_64
# Add  --gpg-key <KEY_ID>  to sign artifacts and SHA256SUMS.

ls -lh dist/release/
# Expect:
#   colinux-lite-x86_64-*.iso
#   SHA256SUMS
#   SHA256SUMS.asc        (only if --gpg-key given)
#   release.json          (manifest with artifact sizes + sha256 + codex version)
```

`release.json` records the bundled Codex CLI version (`codex_version` field) —
include it in the GitHub Release notes so users can correlate CoLinux and
Codex versions.

---

## 4. Publish

### 4.1 Tag and push

```bash
git tag -s v0.2.0 -m "CoLinux Lite v0.2.0 — usability MVP"
git push codexos v0.2.0
# (Use `codexos` remote if `origin` 403s; both point to gibavargas/colinux.)
```

The `release.yml` workflow fires on tag push and creates the draft GitHub
Release with attached artifacts. Verify:

```bash
gh run list --repo gibavargas/colinux --workflow=release.yml --limit 3
gh release view v0.2.0 --repo gibavargas/colinux
```

### 4.2 Release notes (paste into the GitHub Release body)

```
## CoLinux Lite v0.2.0 — Usability MVP

This release establishes the repeatable build → boot → smoke-test →
first-boot dry-run baseline. It is the foundation for all later phases.

### Artifacts
- `colinux-lite-x86_64-*.iso`      — x86_64 live ISO
- `colinux-lite-aarch64-*.iso`     — aarch64 live ISO (EFI only)
- `SHA256SUMS`                     — checksums for all artifacts
- `release.json`                   — manifest with bundled Codex CLI version

### Verified against MVP exit criteria
- [x] `./scripts/smoke-test.sh --all` — PASS
- [x] `./scripts/smoke-test.sh --first-boot` — PASS
- [x] `codex-install-pc --dry-run /dev/sim-nvme0n1` — PASS
- [x] `codex-install-pc --dry-run --dual-boot /dev/sim-nvme0n1` — PASS
- [x] All four Docker editions build cleanly
- [x] No P0/P1 issues open against the v0.2 paths

### Quick start
See `README.md` § Quick Start. Summary:

    docker run --rm -v "$(pwd):/src" -e ARCH=x86_64 -e OUTDIR=/src/dist \
      alpine:3.21 sh -c "apk add --no-cache alpine-sdk apk-tools alpine-conf bash curl \
        ca-certificates git xorriso squashfs-tools mtools dosfstools grub grub-efi \
        efibootmgr e2fsprogs qemu-img openssl && cd /src && bash scripts/build-alpine.sh"
    ./scripts/smoke-test.sh --all
    sudo dd if=dist/colinux-lite-x86_64-*.iso of=/dev/sdX bs=4M status=progress && sync

### Known limitations
- The `colinux-lite-gui`, `colinux-compat`, and `colinux-desktop` editions
  remain experimental; only `colinux-lite` is on the v0.2 stability tier.
- Auto-update and persistence features require post-boot setup
  (`codexctl persist`, `/persist/config/auto-update.conf`).
```

---

## 5. Post-release Verification

Within 1 hour of publishing:

```bash
# 5.1 Download the published ISO from the GitHub Release and re-run smoke tests:
gh release download v0.2.0 --repo gibavargas/colinux \
  --pattern 'colinux-lite-x86_64-*.iso' --dir /tmp/v0.2-verify
./scripts/smoke-test.sh --iso --iso-path /tmp/v0.2-verify/colinux-lite-x86_64-*.iso

# 5.2 Verify published checksums:
cd /tmp/v0.2-verify && sha256sum -c SHA256SUMS

# 5.3 (If signed) verify the signature:
gpg --verify SHA256SUMS.asc SHA256SUMS

# 5.4 Confirm CI is still green on main:
gh run list --repo gibavargas/colinux --limit 5
```

If any of these fail, **do not delete the tag** — cut `v0.2.1` with the fix
and supersede `v0.2.0` in the release notes.

---

## 6. Rollback / Supersede

If a critical issue is found after publication:

1. **Do not delete the tag or release.** Users may have already downloaded it.
2. Mark the GitHub Release as a pre-release and edit the body to begin with
   `⚠️ **Superseded by v0.2.1 — see below.**`
3. Cut a fix commit on `main`, validate with sections 2–5, and tag `v0.2.1`.
4. Update the `v0.2.0` body with a link to the new release.

---

*Last updated: 2026-06-05 — aligned with repo state at v0.2 MVP exit.*
*CoLinux Lite — Alpine Linux + OpenAI Codex CLI*
