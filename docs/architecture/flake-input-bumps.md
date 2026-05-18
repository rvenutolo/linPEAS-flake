# Flake-input bump runbook

This page is the reviewer playbook for the two Renovate PRs that touch
flake-input pins in `flake.nix`:

- **`cachix/git-hooks.nix`** — master HEAD tracker (Renovate manager
  added 2026-05-17, PR #62). Fires whenever upstream master moves.
- **`NixOS/nixpkgs`** — stable-branch tracker (Renovate manager added
  2026-05-17, PR #64). Fires when the next NixOS GA tag (`YY.MM`)
  lands plus the global 7-day `minimumReleaseAge` quarantine.

Both managers are intentionally **manual-merge**. They do pure text
substitution on `flake.nix` and **do not refresh `flake.lock`**, which
is the reason this runbook exists.

## Why a runbook

`renovate.json` defines custom-regex managers that bump the URL fragment
in `inputs.*.url`. Renovate's hosted SaaS does not run
`postUpgradeTasks` (`nix flake update` is not in Mend's allowed-command
list), and switching to self-hosted Renovate for one command would add
significant ops surface for a solo-maintainer repo. See PR #66 (or
search "postUpgradeTasks" in the spec history) for the analysis.

The cost of this gap is one reviewer touch per bump:

- `cachix/git-hooks.nix`: maybe a handful of bumps per year.
- `NixOS/nixpkgs`: twice per year (May `YY.05`, November `YY.11`).

The wide-blast-radius nature of these bumps (especially nixpkgs) means a
human review pass was needed anyway.

## When the Renovate PR arrives

PR title looks like one of:

- `Update dependency cachix/git-hooks.nix to <new-SHA>`
- `Update dependency NixOS/nixpkgs to <YY.MM>`

Diff: exactly one line in `flake.nix` changed. `flake.lock` is **not**
touched. CI required checks will fail on `flake-check` (lock-out-of-date
error) until you complete the steps below.

## Step-by-step

### 1. Check out the PR locally

```bash
gh pr checkout <number>
```

### 2. Refresh `flake.lock`

For a `cachix/git-hooks.nix` bump:

```bash
nix flake update --update-input pre-commit-hooks
```

For a `NixOS/nixpkgs` bump:

```bash
nix flake update --update-input nixpkgs
```

Both commands rewrite `flake.lock` in place. Confirm the diff is sane
(`git diff flake.lock`) — should show new `lastModified` /
`narHash` / `rev` for the relevant node, nothing else.

### 3. Run formatter

Newer nixpkgs ships newer treefmt + prettier + shfmt. These will
sometimes rewrite tracked files (markdown line wraps, blank-line
trimming, etc.). Run the formatter explicitly so the diff lands in this
PR rather than fighting CI:

```bash
nix fmt
```

Stage anything that changes:

```bash
git status
git add <whatever-the-formatter-touched>
```

### 4. Check expected side-effect classes

The 2026-05-17 nixos-25.05 → 25.11 bump (PR #63) hit five distinct
side-effect classes. Use them as a checklist for any future nixpkgs
bump:

| Class | Symptom | Fix |
| --- | --- | --- |
| `prettier` | YAML / Markdown / JSON whitespace diffs | accept the rewrite via `nix fmt` |
| `mkdocs-macros` strictness | `nix build "path:$(pwd)#site"` aborts on a `&#123;&#123; ... &#125;&#125;` literal inside a code block | wrap the offending block in `&#123;% raw %&#125;...&#123;% endraw %&#125;` (mirrors the pre-existing convention in `docs/architecture/ci.md`) |
| `zizmor` major version | `nix flake check` fails on a previously-quiet workflow finding | fix the workflow or, as a last resort, adjust `--min-severity` in `flake.nix` (do not raise above `low` without a security-review entry) |
| `mkdocs --strict` | Build fails on a new plugin warning | fix forward; pin the misbehaving plugin only as a last resort and document the pin reason in the same PR |
| linpeas-image base layers | `image-cve-scan` SARIF changes; `image-smoke` could surface `command not found` regressions | smoke test locally (step 6) — adjust `buildEnv.paths` in `flake.nix` only if a required tool genuinely disappeared from nixpkgs |

`cachix/git-hooks.nix` bumps in isolation usually only hit the `zizmor`
row and only when the pre-commit-hooks repo changes hook versions in
lock-step.

### 5. Build everything

```bash
nix build .#linpeas --print-build-logs
nix build .#linpeas-bundle --print-build-logs
nix build .#linpeas-image --print-build-logs
nix build "path:$(pwd)#site" --print-build-logs
```

The `path:$(pwd)#site` form is required for the `site` derivation —
it bypasses the git filter so the gitignored `docs/_data/dashboard.yml`
is visible to the build (see CLAUDE.md → "GitHub Pages site").

### 6. Run all test suites

```bash
nix develop --command bash tests/gen-dashboard-data.test.sh
nix develop --command bash tests/check-pr-workflows-no-secrets.test.sh
nix develop --command bash tests/check-required-checks-no-paths.test.sh
nix develop --command bash tests/check-tag-protection.test.sh
nix develop --command bash tests/check-renovate-invariants.test.sh
nix develop --command bash tests/check-uses-sha-pinned.test.sh
```

All six must exit 0. If any fail, do **not** disable the test — debug
the regression. The lint scripts encode binding security invariants.

### 7. Image smoke

```bash
nix build .#linpeas-image --out-link result-image
VERSION="$(jq --raw-output .version linpeas-pin.json)"
docker rmi "rvenutolo/linpeas:${VERSION}" 2>/dev/null || true
docker load --input result-image
docker run --rm "rvenutolo/linpeas:${VERSION}" -h 2>&1 \
  | grep --count 'command not found'
# Expect 0
```

A non-zero count means a tool the image previously shipped is missing
from the new nixpkgs. Compare `pkgs.buildEnv.paths` in `flake.nix`
against the missing tool's package name — usually a rename. Update the
path list in the same PR.

### 8. Run `flake check`

```bash
nix flake check --print-build-logs 2>&1 | tail -30
```

All pre-commit hooks must pass: `actionlint`, `deadnix`, `nixpkgs-fmt`,
`treefmt`, `shellcheck`, `statix`, `uses-sha-pinned`, `yamllint`,
`zizmor`, `readme-flake-show-fresh`.

### 9. Commit the refresh

```bash
git add flake.lock <any-side-effect-files>
git commit -m "chore(flake): refresh flake.lock for <pin name>"
git push
```

`treefmt` is wired as a pre-commit hook — it will run on every staged
file change. If it rewrites something, re-stage and commit.

### 10. Wait for CI, merge

Watch the PR's required checks. If everything is green, rebase-merge
through the GitHub UI or `gh pr merge <num> --rebase --delete-branch`.
Note: every commit on the branch must independently satisfy Conventional
Commits (`commitlint` is a required check) since each lands verbatim on
`main`.

### 11. Post-merge

For `NixOS/nixpkgs` bumps specifically:

- The CVE-scan SARIF on `main` will change — surfacing CVEs is
  advisory only (`ci.yml`'s `image-cve-scan` job is intentionally
  outside required-checks). Skim the Security tab for any new
  `CRITICAL` rows. The remediation path for an unfixed
  base-layer CVE is the next nixpkgs bump.
- The Pages cron (14:00 UTC daily) will rebuild the dashboard on its
  next tick. Push-trigger and release-trigger also rebuild
  immediately.
- The next `update-flake-lock.yml` cron run (weekly, Monday 06:00 UTC)
  will refresh within-`YY.MM` patches automatically.

## Interaction between the two pins

If a `NixOS/nixpkgs` bump and a `cachix/git-hooks.nix` bump arrive in
separate Renovate PRs, the order matters when the new nixpkgs `lib`
adds or removes something `git-hooks.nix` depends on (this is the
class of incompatibility that caused GAP-20 in the first place).

The safe order:

1. **Bump `nixpkgs` first.** This forces any `lib` drift to surface
   on a single PR.
2. If `flake check` fails because `git-hooks.nix` is now incompatible,
   bump `git-hooks.nix` in the **same** PR (rebase on top of the
   nixpkgs PR before merging).
3. Then close out the standalone `git-hooks.nix` PR.

If both PRs land cleanly when merged independently, no action needed.

## What changed historically

- 2026-05-17 — GAP-20 closure. Bumped `nixos-25.05` → `nixos-25.11`
  (PR #63). Advanced `pre-commit-hooks` to upstream master `61ab0e80...`.
  Added Renovate trackers for both pins (PRs #62 and #64). See the
  audit spec (`2026-05-17-automated-build-security-audit.md` section
  Wave R-Closed) for the full closure rationale.
