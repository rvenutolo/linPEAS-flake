# Flake-input bump runbook

This page is the reviewer playbook for the Renovate PRs that touch
flake-input pins in `flake.nix`:

- **`cachix/git-hooks.nix`** — master HEAD tracker. Fires whenever
    upstream master moves.
- **`NixOS/nixpkgs`** — stable-branch tracker. Fires when the next
    NixOS GA tag (`YY.MM`) lands plus the global 7-day
    `minimumReleaseAge` quarantine. **Widest blast: runtime, tooling,
    and image base.**
- **`NixOS/nixpkgs-unstable`** — rolling-branch tracker. Fires on
    every upstream commit, grouped weekly by the global
    `before 06:00 on friday` schedule. **Narrow blast: tooling only
    — devShell, CI hooks, formatters, linters, mkdocs. Never touches
    `linpeas-image`.**

Both managers are intentionally **manual-merge**. They do pure text
substitution on `flake.nix` and **do not refresh `flake.lock`**.

The lockfile refresh is performed automatically by the
`renovate-flake-lock-refresh` workflow, which fires on every `ci`
completion against a `renovate/*` branch, detects the bumped input
from the PR title (the `case` arms recognise three title shapes:
`cachix/git-hooks.nix`, `NixOS/nixpkgs-unstable`, and `NixOS/nixpkgs`
— the unstable arm is matched before the stable arm because the stable
string is a substring of the unstable one), runs
`nix flake update --update-input <name>`, and commits the refreshed
`flake.lock` back to the PR branch (App-signed via REST
`PUT /contents`). Watch the PR for a follow-on
`chore(flake): refresh flake.lock for <input>` commit a few minutes
after `ci` first goes green.

The manual runbook below is the **fallback** when the auto-refresh
does not fire — most often because the PR title format changed and
no longer matches the `case` arm in
`.github/workflows/renovate-flake-lock-refresh.yml`. If auto-refresh
silently does not act, an issue is filed under the
`renovate-flake-lock-refresh-failure` label; pursue the manual
steps below in the meantime.

## Why a runbook

`renovate.json` defines custom-regex managers that bump the URL fragment
in `inputs.*.url`. Renovate's hosted SaaS does not run
`postUpgradeTasks` (`nix flake update` is not in Mend's allowed-command
list), and switching to self-hosted Renovate for one command would add
significant ops surface for a solo-maintainer repo.

The cost of this gap is one reviewer touch per bump:

- `cachix/git-hooks.nix`: maybe a handful of bumps per year.
- `NixOS/nixpkgs`: twice per year (May `YY.05`, November `YY.11`).
- `NixOS/nixpkgs-unstable`: weekly, but narrow blast radius.

The wide-blast-radius nature of these bumps (especially nixpkgs) means a
human review pass was needed anyway.

## Expected breakage surface

### Stable (`NixOS/nixpkgs`) bump — wide blast

{% raw %}

A major `NixOS/nixpkgs` bump (e.g. `25.11` → `26.05`) tends to drag in
new versions of every tool the devShell + CI + image touch, plus the
image's bundled runtime payload. The visible fallout falls into a
small set of recurring classes. Walk the full list before merging,
even when CI is green — some failures land later (next cron tick,
next contributor PR).

- **Formatter rewrites.** `nixfmt`, `prettier`, `mdformat`, `shfmt`,
    and `taplo` all move with nixpkgs. A new minor version often
    rewrites whitespace, line wrapping, or quoting conventions across
    Markdown / YAML / JSON / Nix / shell / TOML. Accept via `nix fmt`;
    do not pin around it.
- **mkdocs-macros strictness.** The site build (`nix build "path:$(pwd)#site"`) aborts on a literal `{{ ... }}` outside a Jinja2 raw block. New plugin behavior occasionally
    starts treating a non-template block as macro input. Wrap the
    block in raw tags; do not loosen `--strict`.
- **mkdocs --strict warnings.** Plugin upgrades can promote warnings
    to errors (broken anchors, missing nav entries, deprecated
    options). Fix forward; pin the misbehaving plugin only as a last
    resort and document the pin reason in the same PR.
- **zizmor major version.** New major versions change rule severities
    or add rules that surface on existing workflows. `nix flake check`
    fails on the new finding. Fix the workflow; only as a last resort
    raise `--min-severity` in `nix/hooks/linters.nix` (the `zizmor` hook),
    and never above `low` without a security-review entry.
- **CRITICAL CVEs in image base layers.** `image-cve-scan-trivy` and
    `image-cve-scan-grype` (`image-cve-scan.yml`, weekly cron) are the canonical surface. The new nixpkgs may carry an unfixed
    `CRITICAL` CVE in `coreutils`, `bashInteractive`, `gnused`, etc.
    The CRITICAL-fail gate flags this loudly; the remediation is
    "wait for nixpkgs to patch + bump again", not a code change here.
    Skim the Security tab post-merge.
- **Image base-layer tool renames.** If a tool the image expects
    is gone from the new nixpkgs (rename, removal,
    refactor-to-a-module), `image-smoke`'s `linpeas -h` run inside
    the image will surface `command not found`. Walk
    `pkgs.buildEnv.paths` in `nix/image.nix` against the smoke output.
- **`gh attestation verify` trust-root staleness.** Newer
    `ubuntu-latest` images carry a newer `gh` CLI, which ships an
    updated Sigstore TUF trust-root. A nixpkgs bump does not affect
    this directly, but a coincident runner-image rotation can cause
    spurious verify failures the same day — confirm by re-running the
    `verify-latest-release` cron 24h later before assuming
    attestation drift.
- **pre-commit-hooks lib drift.** When `nixpkgs` lib symbols change
    between releases, `cachix/git-hooks.nix` (and the hooks it
    enables) sometimes break before the project's own pin bumps.
    Surfaces as `nix flake check` failures unrelated to any
    workflow change. See "Interaction between the two pins" below.

Step 4 of the step-by-step below contains the same surface as a
symptom → fix lookup table; use this section to anticipate before
the PR arrives, and the table to triage after CI fails.

{% endraw %}

### Unstable (`NixOS/nixpkgs-unstable`) bump — narrow blast

Tooling-only. Never touches the image runtime payload. The expected
fallout is a strict subset of the stable list:

- **Formatter rewrites.** `nixfmt`, `prettier`, `mdformat`, `shfmt`,
    `taplo`, `just`. Frequent; usually one-line whitespace deltas.
    Accept via `nix fmt`.
- **New linter rules.** `zizmor`, `statix`, `deadnix`, `actionlint`,
    `shellcheck`. Fix forward; raise minimum-severity only as a last
    resort (and never above `low` for `zizmor` without a
    security-review entry).
- **mkdocs / mkdocs-macros plugin churn.** Same shape as the stable
    bump, less frequent than a stable major.

Out of scope for unstable bumps (these only happen on stable):

- Image base-layer rotation / new bundled `coreutils` versions.
- CRITICAL CVEs in runtime payload.

## When the Renovate PR arrives

PR title looks like one of:

- `Update dependency cachix/git-hooks.nix to <new-SHA>`
- `Update dependency NixOS/nixpkgs-unstable to <new-SHA>`
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

For a `NixOS/nixpkgs-unstable` bump:

```bash
nix flake update --update-input nixpkgs-unstable
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

Use the table as a checklist for any nixpkgs bump:

| Class                      | Symptom                                                                                                                                                          | Fix                                                                                                                                                  |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prettier`                 | YAML / Markdown / JSON whitespace diffs                                                                                                                          | accept the rewrite via `nix fmt`                                                                                                                     |
| `mkdocs-macros` strictness | `nix build "path:$(pwd)#site"` aborts on a `&#123;&#123; ... &#125;&#125;` literal inside a code block                                                           | wrap the offending block in `&#123;% raw %&#125;...&#123;% endraw %&#125;` (mirrors the convention in `docs/architecture/ci.md`)                     |
| `zizmor` major version     | `nix flake check` fails on a workflow finding the older version did not surface                                                                                  | fix the workflow or, as a last resort, adjust `--min-severity` in `nix/hooks/linters.nix` (do not raise above `low` without a security-review entry) |
| `mkdocs --strict`          | Build fails on a new plugin warning                                                                                                                              | fix forward; pin the misbehaving plugin only as a last resort and document the pin reason in the same PR                                             |
| linpeas-image base layers  | `image-cve-scan-trivy` / `image-cve-scan-grype` SARIF changes (next weekly scan or manual dispatch); `image-smoke` could surface `command not found` regressions | smoke test locally (step 6) — adjust `buildEnv.paths` in `nix/image.nix` only if a required tool genuinely disappeared from nixpkgs                  |

`cachix/git-hooks.nix` bumps in isolation usually only hit the `zizmor`
row and only when the pre-commit-hooks repo changes hook versions in
lock-step.

### 5. Build everything

```bash
nix build .#linpeas --print-build-logs
nix build .#linpeas-image --print-build-logs
nix build "path:$(pwd)#site" --print-build-logs
```

The `path:$(pwd)#site` form is required for the `site` derivation —
it bypasses the git filter so the gitignored `docs/_data/dashboard.yml`
is visible to the build.

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

A non-zero count means a tool the image expects is missing from the
new nixpkgs. Compare `pkgs.buildEnv.paths` in `nix/image.nix` against the
missing tool's package name — usually a rename. Update the path list
in the same PR.

### 8. Run `flake check`

```bash
nix flake check --print-build-logs 2>&1 | tail -30
```

All pre-commit hooks must pass: `actionlint`, `deadnix`, `nixpkgs-fmt`,
`treefmt`, `shellcheck`, `statix`, `uses-sha-pinned`, `yamllint`,
`zizmor`, `flake-show-fresh`.

### 9. Commit the refresh

```bash
git add flake.lock <any-side-effect-files>
git commit -m "chore(flake): refresh flake.lock for <pin name>"
git push
```

`treefmt` is wired as a pre-commit hook — it will run on every staged
file change. If it rewrites something, re-stage and commit.

### 10. Wait for CI, merge

Watch the PR's required checks. If everything is green, merge-commit
through the GitHub UI or `gh pr merge <num> --merge --delete-branch`.
Note: every commit on the branch must independently satisfy Conventional
Commits (`commitlint` is a required check) and be signed
(`required_signatures` is enforced), since each lands verbatim on
`main` under the merge-commit-only ruleset. The PR title becomes the
merge-commit subject and must itself satisfy Conventional Commits
(`pr-title-lint` is a required check).

### 11. Post-merge

For `NixOS/nixpkgs` bumps specifically:

- The CVE-scan SARIF on `main` will change after the next weekly
    `image-cve-scan.yml` run (or a manual dispatch) — surfacing CVEs is
    advisory only (the `image-cve-scan-trivy` and `image-cve-scan-grype` jobs are intentionally
    outside required-checks). Skim the Security tab for any new
    `CRITICAL` rows. The remediation path for an unfixed
    base-layer CVE is the next nixpkgs bump.
- The Pages cron (14:00 UTC daily) will rebuild the dashboard on its
    next tick. Push-trigger and release-trigger also rebuild
    immediately.
- The next `update-flake-lock.yml` cron run (weekly, Monday 06:00 UTC)
    will refresh within-`YY.MM` patches automatically.

## Interaction between the three pins

If a `NixOS/nixpkgs` bump and a `cachix/git-hooks.nix` bump arrive in
separate Renovate PRs, the order matters when the new nixpkgs `lib`
adds or removes something `git-hooks.nix` depends on.
`NixOS/nixpkgs-unstable` bumps are independent and do not affect the
image; they can land in any order relative to the other two.

The safe order:

1. **Bump `nixpkgs` first.** This forces any `lib` drift to surface
    on a single PR.
1. If `flake check` fails because `git-hooks.nix` is now incompatible,
    bump `git-hooks.nix` in the **same** PR (rebase on top of the
    nixpkgs PR before merging).
1. Then close out the standalone `git-hooks.nix` PR.

If both PRs land cleanly when merged independently, no action needed.

## Reviewer policy

- **Stable (`nixpkgs`) bump:** full walk through every breakage class
    above; verify `linpeas-image` build + bundled-binary version
    inventory; do not auto-trust CI green.
- **Unstable (`nixpkgs-unstable`) bump:** formatter-diff sanity-check
    and CI green is sufficient. Image build is unaffected by definition
    (allocation gates it to stable).
- **`cachix/git-hooks.nix` bump:** hook config diff + CI green.

## update-flake-lock credential split

`update-flake-lock.yml` mirrors the `update-linpeas.yml` split:

- `compute-lock` job has `permissions: contents: read` and must not
    reference `secrets.BUMP_APP_PRIVATE_KEY` or
    `actions/create-github-app-token`. Nix-evaluating actions confined here.
- `push-and-merge` job uses only GitHub-owned action SHAs
    (`actions/checkout`, `actions/download-artifact`,
    `actions/create-github-app-token`, `step-security/harden-runner`). No
    third-party action without a security-review entry.
- Lock updates run via `nix flake update` in the read-only job, not
    via any third-party flake-lock-bumping action.
- App installation token flows only to `gh api` / `gh pr` via `GH_TOKEN`.
    No `git push`. Commit lands via REST `PUT /contents` → web-flow signed.
- `flake.lock` artifact carries JSON shape guard: `push-and-merge`
    verifies `.nodes | type == "object"` before committing.

## renovate-flake-lock-refresh auto-refresh

`renovate-flake-lock-refresh.yml` auto-completes the post-Renovate-PR
lockfile-refresh step that hosted Renovate cannot run itself (no Nix
on Renovate's SaaS runners; no `postUpgradeTasks` allowlist).

Trigger: `workflow_run` of `ci` completing on a `renovate/*` head
branch. The `identify` job gates on ALL of:

- PR author == `renovate[bot]` (or legacy `renovate`).
- PR head branch starts with `renovate/`.
- PR diff touches `flake.nix`.
- PR title contains a known dep name (`cachix/git-hooks.nix` →
    `pre-commit-hooks` input; `NixOS/nixpkgs-unstable` →
    `nixpkgs-unstable` input; `NixOS/nixpkgs` → `nixpkgs` input —
    unstable is matched before stable because the stable string is a
    substring of the unstable title).

Adding a new auto-refreshable input requires three coordinated
edits in the same PR: (1) extend the `case` arm in
`identify`, (2) add a Renovate `customManager` in `renovate.json`,
(3) extend the manual fallback runbook in
`docs/architecture/flake-input-bumps.md`.

Credential split mirrors `update-flake-lock.yml`:

- `identify` + `compute-refresh` jobs: `permissions: contents: read`,
    no App-key reference. Untrusted Nix-evaluating actions confined
    to `compute-refresh`.
- `push-refresh` job: holds `BUMP_APP_PRIVATE_KEY` only. Commits
    refreshed `flake.lock` to PR branch via REST `PUT /contents` →
    web-flow signed by GitHub. No `git push`.

Loop-breaker: `push-refresh` compares `git hash-object flake.lock`
vs branch's blob SHA; bails on match. Protects against the
ci → refresh → ci cycle.

Not in required-checks. Lockfile refresh on a PR cannot block the
PR's own merge gate (chicken-and-egg).
