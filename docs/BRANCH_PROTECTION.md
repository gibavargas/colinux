# Branch Protection Policy

> ROADMAP.md v0.4 deliverable: **Branch protection — main requires CI green + 1 review.**

The `main` branch of `gibavargas/colinux` is protected with classic branch
protection. This file documents the policy and the exact command to re-apply it
(so the configuration is version-controlled, not tribal knowledge).

## Policy

| Rule | Value | Rationale |
|------|-------|-----------|
| Required status checks | `strict` | PRs must be up to date with `main` and pass the CI gate |
| Required contexts | `shellcheck gate`, `bats unit tests`, `markdown lint` | The v0.3/v0.4 quality gate defined in `.github/workflows/ci.yml` |
| Required approving reviews | 1 | External contributions need one review approval before merge |
| Dismiss stale reviews | yes | New pushes to a PR branch dismiss prior approvals |
| Enforce for admins | **no** | The maintainer and the autonomous sprint/release pipeline push directly to `main`; exempting admins preserves that workflow while still gating community/PR contributions |
| Allow force pushes | no | History on `main` is linear and immutable |
| Allow deletions | no | `main` cannot be deleted |

### Why `enforce_admins: false`

The project is developed through a direct-push workflow: the maintainer and the
scheduled autonomous agent commit straight to `main` (see the agent's `git push
codexos main` step). Enforcing the PR + review rule for admins would block that
automation on the very next run. The exemption keeps the established workflow
intact while ensuring **non-admin** collaborators — the public contribution
flow — must open a pull request, get CI green, and earn one approval before
merging. This is the standard configuration for a public solo/small-team OSS
repository.

## Re-apply

The protection is applied via the GitHub REST API. Re-run with:

```bash
gh api -X PUT repos/gibavargas/colinux/branches/main/protection \
  -H "Accept: application/vnd.github+json" \
  --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["shellcheck gate", "bats unit tests", "markdown lint"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": false,
  "block_creations": false
}
JSON
```

## Verify

```bash
gh api repos/gibavargas/colinux/branches/main/protection \
  --jq '{enforce_admins: .enforce_admins.enabled,
         checks: .required_status_checks.contexts,
         reviews: .required_pull_request_reviews.required_approving_review_count}'
```
