# Flake-input bump runbook

This page is the triage runbook for the Renovate PRs that touch
flake-input pins in `flake.nix`:

- **`cachix/git-hooks.nix`** — master HEAD tracker. Fires whenever
    upstream master moves.
- **`NixOS/nixpkgs`** — stable-branch tracker. Fires when the next
    NixOS GA tag (`YY.MM`) lands plus the global 7-day
    `minimumReleaseAge` quarantine. **Blast: the linpeas runtime
    derivation and the image's bundled payload. No tooling.**
- **`nixpkgs-unstable`** — a third input, but **Renovate does not track
    it**. Its URL names a branch that never renames
    (`github:NixOS/nixpkgs/nixos-unstable`), so the weekly
    `update-flake-lock.yml` cron's bare `nix flake update` already floats it
    and lands it as a `chore: update flake.lock` PR. A Renovate manager for
    it would be redundant with that cron, and worse: its only possible edit
    is to replace the branch name in `flake.nix` with a fixed rev, which
    freezes the input and silently stops the manager from ever matching
    again. **Blast: the whole tooling layer — devShell, CI hooks,
    formatters, linters, mkdocs. Never touches `linpeas-image`.**
- **`flake-parts` and `treefmt-nix`** — branch-tracked and likewise
    untracked by Renovate, so the same weekly `nix flake update` floats
    them onto the `chore: update flake.lock` PR. Both carry the 120-day
    staleness bound rather than the 14-day one, because upstream commits in
    bursts. **Blast: `treefmt-nix` owns the formatter wiring, so it lands
    in the same fallout classes as a `nixpkgs-unstable` bump;
    `flake-parts` moves the flake's module plumbing, where breakage
    surfaces as an eval failure rather than a formatting delta.**

Which input owns what is decided in `flake.nix` and `nix/`, not by
branch name. `flake.nix` makes both `treefmt-nix` and `pre-commit-hooks`
set `inputs.nixpkgs.follows = "nixpkgs-unstable"`; `nix/devshell.nix`
builds the shell from `pkgs-unstable`; `nix/treefmt-config.nix` sets
`treefmt.pkgs = pkgs-unstable`; and `nix/hooks/*` reads `pkgs.lib` only,
with one exception — the `nixpkgs-hammering` hook exports
`NIX_PATH="nixpkgs=${inputs.nixpkgs}"` so `nix/hammer-shim.nix` evaluates
the linpeas derivation against stable. The stable-`pkgs` consumers in the
tree are `nix/linpeas.nix`, `nix/image.nix` and that shim. A stable bump
therefore cannot move `nixfmt`,
`prettier`, `mdformat`, `shfmt`, `taplo`, `zizmor`, `statix`, `deadnix`,
`actionlint`, `shellcheck`, or `mkdocs`.

Both Renovate bumps merge unattended once the required check set is green;
see [Dependency-PR merge policy](auto-update.md#dependency-pr-merge-policy)
for the gates that replace a reviewer. The managers do pure text
substitution on `flake.nix` and **do not refresh `flake.lock`**, so a
bump PR is red until the lockfile catches up.

The lockfile refresh is performed automatically by the
`renovate-flake-lock-refresh` workflow, which fires on every `ci`
completion against a `renovate/*` branch, detects the bumped input
from the PR title by handing it to
`scripts/classify-renovate-flake-input.sh`, whose `case` arms recognise
three title shapes — `cachix/git-hooks.nix`, `NixOS/nixpkgs-unstable`,
and `NixOS/nixpkgs`, matched case-insensitively against a lowercased
title, with the unstable arm ahead of the stable one because the stable
string is a substring of the unstable one — then runs
`nix flake update <name>`, and commits the refreshed
`flake.lock` back to the PR branch (App-signed via REST
`PUT /contents`). Watch the PR for a follow-on
`chore(flake): refresh flake.lock for <input>` commit a few minutes
after `ci` first goes green.

The manual runbook below is the **fallback** when the auto-refresh
does not fire, and the reproduction path when a landed bump breaks
something — most often because the PR title format changed and
no longer matches a `case` arm in
`scripts/classify-renovate-flake-input.sh`, or because the author login
GitHub reports moved out of step with
`scripts/classify-renovate-pr-author.sh`. Either way an issue is filed
under the `renovate-flake-lock-refresh-failure` label; pursue the manual
steps below in the meantime.

## Why a runbook

`renovate.json` defines custom-regex managers that bump the URL fragment
in `inputs.*.url`. Renovate's hosted SaaS does not run
`postUpgradeTasks` (`nix flake update` is not in Mend's allowed-command
list), and switching to self-hosted Renovate for one command would add
significant ops surface for a solo-maintainer repo.
`renovate-flake-lock-refresh.yml` closes that gap unattended; this
runbook covers the case where it does not fire, and the case where a
bump that already landed breaks something.

Bump cadence, which sets how often either case comes up:

- `cachix/git-hooks.nix`: maybe a handful of bumps per year.
- `NixOS/nixpkgs`: twice per year (May `YY.05`, November `YY.11`).
- `nixpkgs-unstable`: weekly via the `update-flake-lock.yml` cron, not
    Renovate. Carries the tooling layer.

## Expected breakage surface

### Stable (`NixOS/nixpkgs`) bump — runtime and image base

{% raw %}

A major `NixOS/nixpkgs` bump (e.g. `25.11` → `26.05`) rotates the
image's bundled runtime payload and the linpeas derivation's build
inputs. It does **not** touch the devShell or CI tooling — those follow
`nixpkgs-unstable` (see the ownership note at the top of this page), so
a stable bump cannot move the formatters or the workflow and shell
linters. The one lint it can move is `nixpkgs-hammering`, which evaluates
the linpeas derivation against stable nixpkgs and so fails `flake-check`
on the bump PR itself. The visible
fallout falls into a small set of recurring classes. A green check set
does not clear the list: some of these surface on a later cron tick
rather than on the bump's own checks. Walk the list when one does.

- **CRITICAL CVEs in image base layers.** `image-cve-scan-trivy` and
    `image-cve-scan-grype` (`image-cve-scan.yml`, weekly cron plus a push
    trigger on the paths that change the image) are the canonical surface. The new nixpkgs may carry an unfixed
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
    spurious verify failures the same day — confirm by re-dispatching
    `verify-latest-release` the next day before assuming
    attestation drift.

Step 5 of the step-by-step below contains the same surface as a
symptom → fix lookup table; use this section to anticipate before
the PR arrives, and the table to triage after CI fails.

### Unstable (`nixpkgs-unstable`) bump — the whole tooling layer

Tooling-only. Never touches the image runtime payload. This is where
every formatter, linter and site-build regression comes from, and it
lands weekly on the cron's lockfile PR rather than on a Renovate one:

- **Formatter rewrites.** `nixfmt`, `prettier`, `mdformat`, `shfmt`,
    `taplo`, `just`. Frequent; usually one-line whitespace deltas, but a
    new minor version can rewrite wrapping or quoting conventions across
    Markdown / YAML / JSON / Nix / shell / TOML. Accept via `nix fmt`;
    do not pin around it.
- **New linter rules.** `zizmor`, `statix`, `deadnix`, `actionlint`,
    `shellcheck`. A new `zizmor` major changes rule severities or adds
    rules that surface on existing workflows, failing `nix flake check`.
    Fix forward; raise `--min-severity` in `nix/hooks/linters.nix` only
    as a last resort, and never above `low` without a security-review
    entry.
- **mkdocs-macros strictness.** The site build
    (`nix build "path:$(pwd)#site"`) aborts on a literal `{{ ... }}`
    outside a Jinja2 raw block. New plugin behavior occasionally starts
    treating a non-template block as macro input. Wrap the block in raw
    tags; do not loosen `--strict`.
- **mkdocs --strict warnings.** Plugin upgrades can promote warnings to
    errors (broken anchors, missing nav entries, deprecated options).
    Fix forward; pin the misbehaving plugin only as a last resort and
    document the pin reason in the same PR.
- **pre-commit-hooks lib drift.** `cachix/git-hooks.nix` follows
    `nixpkgs-unstable`, so when lib symbols move under it the hooks it
    enables sometimes break before that pin's own bump lands. Surfaces
    as `nix flake check` failures unrelated to any workflow change. See
    "Interaction between the pins" below.

Out of scope for unstable bumps (these only happen on stable):

- Image base-layer rotation / new bundled `coreutils` versions.
- CRITICAL CVEs in runtime payload.

{% endraw %}

## When the Renovate PR arrives

PR title looks like one of:

- `Update cachix/git-hooks.nix digest to <new-SHA>`
- `Update NixOS/nixpkgs to <version>`

Only the dependency-name substring is matched, so the surrounding wording
is not load-bearing — the `identify` job shells out to
`scripts/classify-renovate-flake-input.sh`, whose `case` arms glob on
`cachix/git-hooks.nix`, `NixOS/nixpkgs-unstable` and `NixOS/nixpkgs`
(matched against a lowercased title, so capitalisation does not matter).
A title that stops carrying one of those substrings is what silently
stops the auto-refresh.

The classifier keeps its `NixOS/nixpkgs-unstable` arm even though no
manager emits that title: `NixOS/nixpkgs` is a substring of
`NixOS/nixpkgs-unstable`, so deleting the arm as dead code would send any
title naming unstable to the stable arm and refresh the wrong input.

Diff: exactly one line in `flake.nix` changed. `flake.lock` is **not**
touched. CI required checks fail on `flake-check` (lock-out-of-date
error) until the lockfile catches up — normally through the
auto-refresh above, and through the steps below when it does not
fire. A bump therefore cannot auto-merge on the strength of the
`flake.nix` line alone.

Every one of these bumps repoints an input's source, which is what the
`flake.lock` input-provenance gate exists to catch. It passes here because
the repoint is *declared*: the gate reads `flake.nix` on both sides and
tolerates a lock move for an input whose declared `url` moved with it,
logging a note that names both. The corroboration is per input name, so a
lock carrying a second, undeclared repoint alongside the declared one still
fails. See [the gate's section in the trust
model](../security/trust-model.md#flakelock-input-provenance-gate).

## Step-by-step

### 1. Check out the PR locally

```bash
gh pr checkout <number>
```

### 2. Refresh `flake.lock`

For a `cachix/git-hooks.nix` bump:

```bash
nix flake update pre-commit-hooks
```

For a `NixOS/nixpkgs` bump:

```bash
nix flake update nixpkgs
```

Both commands rewrite `flake.lock` in place. Confirm the diff is sane
(`git diff flake.lock`) — should show new `lastModified` /
`narHash` / `rev` for the relevant node, nothing else.

### 3. Run formatter

A newer `nixpkgs-unstable` ships newer treefmt + prettier + shfmt.
These will sometimes rewrite tracked files (markdown line wraps,
blank-line trimming, etc.). Run the formatter explicitly so the diff
lands in this PR rather than fighting CI. A stable-only bump leaves the
formatters untouched, so this step is a no-op there:

```bash
nix fmt
```

Stage anything that changes:

```bash
git status
git add <whatever-the-formatter-touched>
```

### 4. Regenerate the lock-derived docs

Several tracked docs are generated from evaluated flake state, so the
refreshed lock can leave them stale. Run each generator named in the
lock-writing workflow's `LOCK_DERIVED_GENERATORS` list and commit the
changed docs alongside the lock:

```bash
nix develop --command bash scripts/refresh-flake-show.sh
nix develop --command bash scripts/refresh-treefmt-config.sh
```

See [Lock-derived docs travel with the lock](#lock-derived-docs-travel-with-the-lock)
for what asserts that list.

### 5. Check expected side-effect classes

Use the table as a checklist for any nixpkgs bump. The first four rows
belong to `nixpkgs-unstable`, which owns the tooling layer; the last two
can fire on a stable bump:

| Class                      | Symptom                                                                                                                                                                                             | Fix                                                                                                                                                  |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prettier`                 | YAML / Markdown / JSON whitespace diffs                                                                                                                                                             | accept the rewrite via `nix fmt`                                                                                                                     |
| `mkdocs-macros` strictness | `nix build "path:$(pwd)#site"` aborts on a `&#123;&#123; ... &#125;&#125;` literal inside a code block                                                                                              | wrap the offending block in `&#123;% raw %&#125;...&#123;% endraw %&#125;` (mirrors the convention in `docs/architecture/ci.md`)                     |
| `zizmor` major version     | `nix flake check` fails on a workflow finding the older version did not surface                                                                                                                     | fix the workflow or, as a last resort, adjust `--min-severity` in `nix/hooks/linters.nix` (do not raise above `low` without a security-review entry) |
| `mkdocs --strict`          | Build fails on a new plugin warning                                                                                                                                                                 | fix forward; pin the misbehaving plugin only as a last resort and document the pin reason in the same PR                                             |
| `nixpkgs-hammering`        | `nix flake check` fails on a nixpkgs idiom the older stable branch did not flag, against the linpeas derivation                                                                                     | fix `nix/linpeas.nix` forward; suppress in `nix/hammer-shim.nix` only with a reason in the same PR                                                   |
| linpeas-image base layers  | `image-cve-scan-trivy` / `image-cve-scan-grype` SARIF changes (the merge itself triggers a scan, since `flake.lock` is a trigger path); `image-smoke` could surface `command not found` regressions | smoke test locally (step 8) — adjust `buildEnv.paths` in `nix/image.nix` only if a required tool genuinely disappeared from nixpkgs                  |

`cachix/git-hooks.nix` bumps in isolation usually only hit the `zizmor`
row and only when the pre-commit-hooks repo changes hook versions in
lock-step.

### 6. Build everything

```bash
nix build .#linpeas --print-build-logs
nix build .#linpeas-image --print-build-logs
nix build "path:$(pwd)#site" --print-build-logs
```

The `path:$(pwd)#site` form is required for the `site` derivation —
it bypasses the git filter so the gitignored `docs/_data/dashboard.yml`
is visible to the build.

### 7. Run all test suites

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

### 8. Image smoke

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

### 9. Run `flake check`

```bash
nix flake check --print-build-logs 2>&1 | tail -30
```

All pre-commit hooks must pass. Representative ones for a flake-input
bump: `actionlint`, `deadnix`, `nixfmt`, `treefmt`, `shellcheck`,
`statix`, `uses-sha-pinned`, `yamllint`, `zizmor`, `flake-show-fresh`.
The full, generated list is in
[Git workflow → Pre-commit hooks](../development/git.md#pre-commit-hooks).

### 10. Commit the refresh

```bash
git add flake.lock <any-side-effect-files>
git commit -m "chore(flake): refresh flake.lock for <pin name>"
git push
```

`treefmt` is wired as a pre-commit hook — it will run on every staged
file change. If it rewrites something, re-stage and commit.

### 11. Wait for CI

Watch the PR's required checks. On green the PR merges itself —
`automerge` is scoped to every flake-input manager. To stop a bump
from landing, close the PR: disabling auto-merge does not hold,
because Renovate re-arms it on its next run over the repo.
Note: every commit on the branch must independently satisfy Conventional
Commits (`commitlint` is a required check) and be signed
(`required_signatures` is enforced), since each lands verbatim on
`main` under the merge-commit-only ruleset. The PR title becomes the
merge-commit subject and must itself satisfy Conventional Commits
(`lint-pr-title` is a required check).

### 12. Post-merge

For `NixOS/nixpkgs` bumps specifically:

- The CVE-scan SARIF on `main` updates on the merge itself:
    `image-cve-scan.yml` triggers on a push touching `flake.lock`, so a
    nixpkgs bump rescans without waiting for the Friday cron. Surfacing
    CVEs is advisory only (the `image-cve-scan-trivy` and
    `image-cve-scan-grype` jobs are intentionally outside
    required-checks), so the run does not gate the merge — skim the
    Security tab for any new `CRITICAL` rows once it finishes. The
    remediation path for an unfixed base-layer CVE is the next nixpkgs
    bump.
- The Pages cron (daily) will rebuild the dashboard on its
    next tick. Push-trigger and release-trigger also rebuild
    immediately.
- The next `update-flake-lock.yml` cron run (weekly, Friday)
    will refresh within-`YY.MM` patches automatically.

## Interaction between the pins

If a `NixOS/nixpkgs` bump and a `cachix/git-hooks.nix` bump arrive in
separate Renovate PRs, the order matters when the new nixpkgs `lib`
adds or removes something `git-hooks.nix` depends on.
`nixpkgs-unstable` bumps are independent and do not affect the image;
they arrive on the cron's own lockfile PR and can land in any order
relative to the other two.

The safe order:

1. **Bump `nixpkgs` first.** This forces any `lib` drift to surface
    on a single PR.
1. If `flake check` fails because `git-hooks.nix` is now incompatible,
    bump `git-hooks.nix` in the **same** PR (rebase on top of the
    nixpkgs PR before merging).
1. Then close out the standalone `git-hooks.nix` PR.

If both PRs land cleanly when merged independently, no action needed.

That order is advisory, not enforced: both PRs auto-merge on green, so
whichever goes green first lands first. The failure mode is benign —
if a landed `nixpkgs` bump makes the pinned `git-hooks.nix` revision
incompatible, the `git-hooks.nix` PR rebases onto it, `flake check`
goes red, and the PR sits until the incompatibility is fixed forward.

## What a green check set proves

Every input merges on green. What that green establishes differs by
input:

- **Stable (`nixpkgs`) bump:** the weakest of the three. The
    `linpeas-image` build and the bundled-binary inventory are covered
    at PR time, but several breakage classes above are not reproducible
    then — CVE-scan output and the dashboard rebuild both resolve later.
    Treat the first weekly cron cycle after a stable bump as part of the
    bump.
- **Unstable (`nixpkgs-unstable`) bump**, which reaches `main` on the
    cron's lockfile PR rather than a Renovate one, carrying any
    `flake-parts` and `treefmt-nix` movement with it: close to conclusive.
    Formatter and linter churn is exactly what the required checks
    execute, and the image build is unaffected by definition
    (allocation gates it to stable).
- **`cachix/git-hooks.nix` bump:** conclusive for the hook config,
    which is the entire surface the input touches.

## update-flake-lock credential split

`update-flake-lock.yml` mirrors the `update-linpeas.yml` split:

- `compute-lock` job has `permissions: contents: read` and must not
    reference `secrets.BUMP_APP_PRIVATE_KEY` or
    `actions/create-github-app-token`. Nix-evaluating actions confined here.
- `push-and-merge` job uses only `actions/*` SHAs plus the repo-wide
    `step-security/harden-runner` pin
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

- PR author is the Renovate App, decided by
    `scripts/classify-renovate-pr-author.sh`. GitHub reports the same App
    under three spellings — `app/renovate` from `gh pr view --json author`, `renovate[bot]` from the REST and GraphQL APIs, and a bare
    `renovate` from a self-hosted legacy install — so the classifier
    normalizes one optional `app/` prefix and one optional `[bot]`
    suffix and then matches `renovate` exactly. A login that merely
    contains `renovate` is rejected: this workflow pushes commits to a
    PR branch, and `renovate` is a claimable username shape. Unlike the
    other gates below, an author that does not match FAILS the
    `identify` job rather than skipping it — every PR reaching this point
    is on a `renovate/` branch, so an author Renovate does not own is an
    anomaly, and a silent skip is what let an earlier login-shape change
    disable the whole workflow undetected.
- PR head branch starts with `renovate/`.
- PR diff touches `flake.nix`.
- PR title contains a known dep name (`cachix/git-hooks.nix` →
    `pre-commit-hooks` input; `NixOS/nixpkgs` → `nixpkgs` input). The
    classifier also maps `NixOS/nixpkgs-unstable` → `nixpkgs-unstable`
    and matches it before stable, because the stable string is a
    substring of the unstable title. No manager emits that title now,
    and the arm stays for exactly that reason: dropping it would route
    an unstable title to the stable arm.

Adding a new auto-refreshable input requires three coordinated
edits in the same PR: (1) extend the `case` arms in
`scripts/classify-renovate-flake-input.sh`, which the `identify` job
invokes (and extend its test harness alongside; the same pairing applies
to `scripts/classify-renovate-pr-author.sh` if a login shape moves),
(2) add a Renovate `customManager` in `renovate.json`,
(3) extend the manual fallback runbook in
`docs/architecture/flake-input-bumps.md`.

Credential split mirrors `update-flake-lock.yml`:

- `identify` job: `permissions: contents: read` + `pull-requests: read`
    (it reads PR author, branch, diff, and title). `compute-refresh` job:
    `permissions: contents: read`. Neither references the App key.
    Untrusted Nix-evaluating actions confined
    to `compute-refresh`.
- `push-refresh` job: holds `BUMP_APP_PRIVATE_KEY` only. Commits
    refreshed `flake.lock` to PR branch via REST `PUT /contents` →
    web-flow signed by GitHub. No `git push`.

Loop-breaker: `push-refresh` compares `git hash-object flake.lock`
vs branch's blob SHA; bails on match. Protects against the
ci → refresh → ci cycle.

Reporting: the `notify` job runs whenever `identify` ran, and
`scripts/classify-refresh-notify-result.sh` decides what the run
amounts to — `failure` files the deduped
`renovate-flake-lock-refresh-failure` issue, `success` closes it, and
`skipped` is inert in the composite. The verdict lives in a script
rather than in the job's `if:` gate because a gate reading `identify`'s
outputs cannot see an `identify` that failed: a failed job sets no
outputs, so its failure and its ordinary early exit look identical from
the gate. That matters most here, because this workflow reacts to
someone else's PR — a red run in the Actions tab has no watcher at the
moment it goes red, and the PR it was meant to repair sits with a
failing `flake-check` instead. A combination the job graph cannot
produce classifies as `failure` too: an issue naming a drifted workflow
beats the silence. `tests/classify-refresh-notify-result.test.sh` holds
the matrix, including both ends of it — a failed `identify` reports, and
a `ci` completion that is not a Renovate flake bump stays silent.

Not in required-checks. Lockfile refresh on a PR cannot block the
PR's own merge gate (chicken-and-egg).

## Lock-derived docs travel with the lock

Several docs in this repo are generated from evaluated flake state, so a
`flake.lock` bump can make them stale without touching any other tracked
file — `docs/reference/flake-outputs.md` embeds the package versions
`nix flake show` renders, and a `nixpkgs` bump moves them.

Every workflow that writes a lock therefore regenerates that set
alongside it and commits each changed file as its own signed commit.
Two workflows do: `update-flake-lock.yml`, which opens the weekly bump
PR, and `renovate-flake-lock-refresh.yml`, which refreshes the lock on a
Renovate flake-input PR. Each declares the set in two workflow-level
`env` lists: `LOCK_DERIVED_GENERATORS` names the generators it runs, and
`COMMITTABLE_PATHS` bounds what the credentialed job is allowed to
commit — the compute job holds no write credential, so that list, not the
artifact it uploads, is the trust boundary.

The second list is not written by hand against the first. Every
generator already declares what it writes in its own comment header —
`@generates <path>` for a file it owns outright and
`@generates-block <path>` for a region it splices into a hand-authored
file — and the committable set is exactly `flake.lock` plus those
declared outputs. Both annotation kinds count: the split between whole
file and spliced block is a judgment about who owns the surrounding
prose, not about who writes the bytes. `flake.lock` is on the list
because the workflow writes it directly rather than through a
generator.

`scripts/check-lock-derived-docs.sh` asserts the two stay in agreement
with the hooks that declare the dependency. It discovers its subjects
rather than naming them: every workflow carrying a lock update in a `run`
block must declare both lists, every freshness hook whose `files` regex
names `flake.lock` must have its generator in that workflow's
`LOCK_DERIVED_GENERATORS`, and every entry there must be backed by such a
hook. A hook that names `flake.lock` a trigger while naming no generator
fails the same way — the two halves of one declaration disagreeing is
drift, not a hook the lint may quietly ignore. A workflow declaring the
lists while running no lock update fails too: the lists outlived the step
they bounded, and nothing reads them. Adding a lock-derived generator
without teaching every lock-writing workflow to run it fails the lint
rather than surfacing later as a PR that cannot merge.

It asserts the committable binding in both directions, per workflow. A
path a listed generator declares but `COMMITTABLE_PATHS` omits is drift:
the compute job regenerates the doc, the credentialed job may not commit
it, and the doc reaches the PR exactly as stale as if the generator had
never run — on a branch nobody is watching, where the only signal is the
required freshness gate failing after the fact. A `COMMITTABLE_PATHS`
entry no listed generator declares is drift in the other direction: it
widens what the credentialed job may commit past anything the bump
produces. So is a listed generator that declares no output at all —
running a generator whose writes are bound to nothing puts its doc
outside the check entirely, which is the first failure wearing a
compliant-looking list.
