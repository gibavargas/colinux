# CoLinux test harness

Automated quality gate for CoLinux. Three suites, one runner.

## Quick start

```bash
# from the repo root
make test            # lint + unit (default; the v0.3 gate)
make lint            # shellcheck only
make test-iso        # QEMU boot regression (needs a built ISO + QEMU)

# or invoke the runner directly
./tests/run-tests.sh           # lint + unit
./tests/run-tests.sh all       # lint + unit + iso
```

## Suites

| Suite | What it checks | Gate | Exit criterion |
|-------|----------------|------|----------------|
| `lint`  | `shellcheck` on `scripts/*.sh` (zero warnings) + informational report on all `codex-*` wrappers | ✅ gating | `shellcheck scripts/*.sh` clean |
| `unit`  | `bats` tests: syntax, shebang, `set -euo pipefail`, `--help`, `die()`, no `grep -oP`, no `eval`/`source` on untrusted input, logging convention, no masked `***` secret writes, **build reproducibility contract** (repo snapshot pinning, APKINDEX capture, checksum + manifest generation) | ✅ gating | `bats tests/` green |
| `iso`   | Boots the built ISO in QEMU and checks kernel/init/network/persistence via serial console (delegates to `scripts/test-iso.sh`) | ✅ when run | ISO boots to login |

### Layout

```
tests/
├── README.md            # this file
├── run-tests.sh         # master runner (lint | unit | iso | all)
├── install-bats.sh      # vendors bats-core into tests/.bats/ (no sudo)
├── lib/
│   └── helpers.bash     # shared discovery + assertion helpers
├── lint/
│   └── shellcheck.sh    # shellcheck gate + wrapper report
├── unit/
│   ├── syntax.bats      # bash -n + shebang/bashism checks for all scripts
│   ├── wrappers.bats    # codex-* contract & security checks
│   └── build.bats       # build-alpine.sh reproducibility contract checks
└── .gitignore
```

## bats

`bats` is **not** a system dependency. `run-tests.sh` uses a system `bats` if
present, otherwise `install-bats.sh` clones [bats-core](https://github.com/bats-core/bats-core)
into the gitignored `tests/.bats/`. To install manually:

```bash
./tests/install-bats.sh
export PATH="$PWD/tests/.bats/bin:$PATH"
bats tests/unit
```

## Adding tests

* New `codex-*` wrappers and `scripts/*.sh` files are picked up automatically
  by the discovery helpers in `lib/helpers.bash` — no test edits required.
* Add a new `.bats` file under `tests/unit/`; `bats tests/unit` runs all of them.
* The wrapper contract tests encode the P0/P1 audit checklist; when a new
  security invariant is added to the audit process, add a `@test` here so it is
  enforced going forward.

## Design notes

* **Runtime tests vs static contract tests.** Most `codex-*` wrappers hardcode
  `PERSIST_DIR=/persist` and `mkdir` it at load time, which makes them
  un-executable as a non-root user. The bats suite therefore enforces the
  **contract** (syntax, flags, security patterns, conventions) statically. Full
  runtime/behavioral coverage is a follow-up once `PERSIST_DIR` is made
  overridable — a separate hardening task.
* **Cross-edition drift.** `colinux_list_wrappers` enumerates every `codex-*`
  shell script across all four editions *plus* `installer/` and `disk/` copies,
  so the same bug (e.g. a `grep -oP` or a missing `--help`) is caught in every
  edition at once.
