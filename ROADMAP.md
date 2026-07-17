# CoLinux Lite — Roadmap to v1.0

> **Current:** v0.2 MVP (Usability baseline — build, boot, smoke-test, first-boot dry-run all pass)
> **Goal:** v1.0 — Production-grade, community-ready release

---

## Phase Overview

```
v0.2 ──── v0.3 ──── v0.4 ──── v0.5 ──── v0.6 ──── v0.7 ──── v0.8 ──── v0.9 ──── v1.0
 MVP      Hardening  CI/CD     Install   GUI/      Remote    i18n/     RC        GA
                             & Update  Desktop   & Cloud    Docs
```

---

## v0.3 — Hardening & Test Coverage
*Target: 2–3 weeks*

The MVP works but has no automated test suite and the build scripts carry
significant technical debt (6 KLOC of shell with zero unit tests).

### Deliverables
- [x] **Test harness** — `tests/` directory with:
  - Shellcheck lint pass on all `scripts/*.sh` (zero warnings)
  - Unit tests for `codex-*` wrapper scripts (`bats` framework)
  - ISO boot regression test integrated into `test-iso.sh` (already partial)
- [x] **Build reproducibility** — pinned Alpine repo snapshot + checksums in build
- [x] **Error handling audit** — every `codex-*` command returns structured JSON on `--json`
- [ ] **Logging standardization** — all scripts emit to `/persist/logs/` with rotation
- [ ] **First-boot idempotency** — `first-boot.sh` safe to re-run without side effects

### Exit criteria
- `shellcheck scripts/*.sh` passes with zero warnings
- `bats tests/` green
- ISO builds reproducibly (same input → same SHA-256 two builds in a row)

---

## v0.4 — CI/CD Pipeline
*Target: 2–3 weeks after v0.3*

Repetitive audit/fix cycles dominate the commit log. Automate the quality gate.

### Deliverables
- [ ] **GitHub Actions CI** — on PR and push to main:
  - `shellcheck` + `bats` + markdown lint
  - Docker ISO build (`colinux-lite` edition)
  - QEMU smoke test via `test-iso.sh` (serial console)
  - Artifact upload (ISO + checksums)
- [ ] **Release automation** — tag-triggered:
  - Build all stable editions
  - Generate SHA-256 + GPG signatures
  - GitHub Release with artifacts + changelog
- [ ] **Nightly builds** — `build-alpine.sh` on cron, publish to `nightly` tag
- [ ] **Branch protection** — main requires CI green + 1 review

### Exit criteria
- PR merges blocked on CI green
- Tag push produces a GitHub Release automatically
- Nightly ISO downloadable from Releases page

---

## v0.5 — Installer & Update System
*Target: 3–4 weeks after v0.4*

Currently installation is `dd`-based and updates are cron-based Codex-only.
Need a proper installer and in-place OS updates.

### Deliverables
- [ ] **`codex-install` TUI** — interactive installer:
  - Disk selection with safety confirmation
  - Partition layout (EFI + root + persist)
  - LUKS encryption option
  - Dual-boot EFI entry preservation
  - Validation before writing
- [ ] **`codex-update` OS-level** — update the full appliance:
  - A/B partition scheme (fallback on failed update)
  - Signature verification on update payloads
  - Rollback mechanism
- [ ] **`codex-snapshot` improve** — snapshots include version metadata
- [ ] **USB persistence wizard** — guided `codex-usb-persist` setup

### Exit criteria
- Clean install to bare metal via `codex-install`
- In-place update with automatic rollback on failure
- Persistence survives update

---

## v0.6 — GUI & Desktop Stabilization
*Target: 3–4 weeks after v0.5*

GUI and Debian editions are experimental. Bring them to stable.

### Deliverables
- [ ] **`colinux-lite-gui` stable** — cage + sway + foot:
  - Tested on 3+ real hardware configs
  - Resolution auto-detection
  - On-screen keyboard for tablets
- [ ] **`colinux-compat` stable** — Debian-based fallback:
  - Parity with Alpine edition on all `codex-*` commands
  - Systemd service hardening
- [ ] **`colinux-desktop` MVP** — Electron + Codex:
  - Browser-based Codex interface
  - Desktop icon / app launcher
- [ ] **ARM64 support** — `aarch64` builds for Raspberry Pi 4/5

### Exit criteria
- GUI edition boots on real hardware with display
- Debian compat passes same smoke tests as Alpine
- ARM64 ISO boots on Raspberry Pi 5

---

## v0.7 — Remote & Cloud Integration
*Target: 2–3 weeks after v0.6*

CoLinux's power is in remote/ headless use. Make it a first-class experience.

### Deliverables
- [ ] **`codex-remote` overhaul**:
  - SSH key management (generate, import, rotate)
  - Cloudflare Tunnel one-command setup
  - Tailscale integration
  - mDNS discovery (`.local` addressing)
- [ ] **`codex-pxe` production** — network boot:
  - DHCP + TFTP + HTTP served from CoLinux
  - Provision other machines headlessly
- [ ] **Web UI** — browser-based terminal:
  - `ttyd` or `gotty` integrated
  - Access CoLinux from any device on the network
- [ ] **REST API** — `codexctl serve`:
  - `/api/v1/disk`, `/api/v1/network`, `/api/v1/system`
  - JSON API for programmatic control

### Exit criteria
- Remote access from another machine in under 60 seconds
- PXE boot provisions a target machine
- Web UI accessible from phone/tablet

---

## v0.8 — Internationalization & Documentation
*Target: 2–3 weeks after v0.7*

Prepare for non-English users and comprehensive docs.

### Deliverables
- [ ] **i18n** — all user-facing strings externalized:
  - Portuguese (pt-BR) as first translation
  - English (en) as default
  - Weblate or similar for community translations
- [ ] **Docs site** — Docusaurus or MkDocs:
  - Getting Started guide
  - All `codex-*` command reference
  - Hardware compatibility list
  - Troubleshooting FAQ
  - Video tutorials (embedded)
- [ ] **Man pages** — `man codex-disk-inventory` etc.
- [ ] **Contributing guide** — `CONTRIBUTING.md` with:
  - Code style (shellcheck, shfmt)
  - PR process
  - Release process

### Exit criteria
- Docs site live at colinux.dev (or GitHub Pages)
- All commands have `--help` + man page
- pt-BR translation complete

---

## v0.9 — Release Candidate
*Target: 2–3 weeks after v0.8*

Feature freeze. Only bug fixes and polish.

### Deliverables
- [ ] **Security audit** — external review:
  - Disk safety model validation
  - LUKS implementation review
  - Update signature chain verification
  - `doas` policy audit
- [ ] **Performance** — boot time, memory, image size:
  - Boot under 8 seconds on SSD
  - RAM usage under 200 MB at idle
  - ISO under 150 MB (Alpine lite)
- [ ] **Hardware certification** — tested on:
  - 5+ laptop models
  - 3+ server models
  - Raspberry Pi 4/5 (ARM64)
  - Various USB drives (USB 2.0 and 3.0)
- [ ] **Accessibility** — screen reader support in GUI edition
- [ ] **Migration tool** — upgrade from v0.2/0.5 to v0.9 in-place

### Exit criteria
- Zero P0/P1 bugs
- Security audit passed
- Hardware certification matrix documented

---

## v1.0 — General Availability
*Target: 4–6 weeks after v0.9 RC*

Polish, marketing, community launch.

### Deliverables
- [ ] **Release blog post** — "CoLinux Lite 1.0: Your AI Rescue USB"
- [ ] **Demo video** — 5-minute walkthrough
- [ ] **GitHub Release** — signed ISOs for all stable editions
- [ ] **Community channels** — Discord/Matrix + discussions
- [ ] **Homebrew/cask** — `brew install --cask colinux` (macOS USB flasher)
- [ ] **Windows flasher** — Rufus-compatible ISO + Etcher support
- [ ] **Stable API contract** — `codexctl` v1 API, no breaking changes until v2

### Exit criteria
- Public announcement
- 100+ GitHub stars in first week (aspirational)
- Zero data-loss incidents in release period

---

## Backlog (Post-1.0)

Items that are valuable but don't block the 1.0 release:

- **Plugin system** — third-party `codex-*` commands via `/persist/plugins/`
- **Multi-agent** — CoLinux as orchestration hub for remote Hermes/Codex agents
- **Container runtime** — podman/docker for isolated workloads
- **ZFS support** — advanced filesystem management
- **Secure Boot** — signed boot chain
- **TPM** — remote attestation
- **Cloud images** — AWS AMI, GCP image, Vultr snapshot
- **Mobile companion** — iOS/Android app for remote `codexctl`
