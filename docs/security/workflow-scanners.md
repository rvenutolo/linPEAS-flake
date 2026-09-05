# Workflow-scanner division of labor

Several tools analyze `.github/workflows/**`. Their coverage overlaps on
purpose: each catches failure modes the others structurally cannot. This page
records the layered model so the overlap reads as a budgeted defense-in-depth
posture, not redundancy to trim.

!!! warning "Do not trim a layer"

    Removing any layer below requires a
    [security-review entry](https://github.com/rvenutolo/linPEAS-flake/blob/main/CONTRIBUTING.md#security-review-entries).
    Do not drop one because another "already covers it" — the whole point is
    that no single layer covers every vector.

## The layered model

Workflow scanning runs at four moments, each with a blind spot the next layer
closes:

| Layer                  | When it fires                                                                      | Tools                                                                                                                                                                                          | Closes the gap of                                                                         |
| ---------------------- | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Commit-time prevention | every `git commit` touching a scanned path (pre-commit)                            | zizmor, octoscan + the workflow-hardening hook family                                                                                                                                          | bad edits caught before they reach history, on the local path                             |
| PR / push detection    | every PR to `main` (codeql full; octoscan paths-filtered) and every push to `main` | codeql, octoscan, zizmor (re-run by the required `flake-check` job's `nix flake check`), and the required lint-group jobs (lint-workflow-security / lint-script-hygiene / lint-doc-invariants) | changed workflows checked server-side, in the diff                                        |
| Weekly full sweep      | Friday cron cluster                                                                | codeql, octoscan, zizmor                                                                                                                                                                       | a scheduled re-scan of `main`, paged as a deduped issue, with no PR or push to trigger it |
| Posture watchdog       | daily + weekly cron                                                                | scorecard-drift-check, ratchet-pin-audit, settings-posture-drift-check, stale-pin-check, allowed-actions-api-drift-check, flake-lock-staleness-check                                           | silent regressions no single PR introduces                                                |

Commit-time prevention is the cheapest and earliest gate, but it is bypassable
(`--no-verify`, edits made in the GitHub web UI or by bots before hooks
re-run). PR/push detection re-checks every change server-side. The weekly
sweep re-runs the same pinned scanners against `main` on a schedule, so a
finding on `main` is paged as a deduped issue even when no push has run the
scanners since — codeql and octoscan are advisory on PRs and page only from
non-PR runs, and zizmor's run re-verifies what the required `flake-check` job
already scans. A tightened rule arrives with the PR that bumps the scanner's
pin, and that PR's own runs re-scan the files. The posture watchdogs catch drift
that accrues across commits — a force-moved tag, a loosened setting — that no
individual diff reveals.

## The four external tools

These are third-party security scanners, distinct from the in-tree lints
and posture watchdogs indexed in the next section (which also lists the
upstream `actionlint` hook alongside them). The weekly Friday cron cluster
runs them in a fixed order (see
[CI — cron schedule](../architecture/ci.md#cron-schedule) for the exact slots):

1. codeql (`codeql.yml`)
1. octoscan (`octoscan.yml`)
1. scorecard (`scorecard-drift-check.yml`)
1. zizmor (`zizmor-drift-check.yml`)

(scorecard shares the same Friday cluster but is classed as a
posture watchdog — the `scorecard-drift-check` row — in the layer
table above, since it grades posture rather than re-scanning the
tree.)

### codeql

- **Unique signal:** dataflow / taint analysis of workflow and
    composite-action files (the `actions` query pack). Catches injection
    reachable through variable flow that pattern matchers miss.
- **Triggers:** every PR to `main` (no paths filter); push to `main`; weekly
    Friday cron (full tree); manual dispatch. It runs on every PR — not just
    workflow-touching ones — so the OpenSSF Scorecard SAST check, which the
    in-tree `scorecard-drift-check` deliberately does not grade, sees a SAST
    tool on every merged PR (it scores the fraction analysed). The `actions`
    pack re-analyses the whole tree each run (~1 min), so a PR touching
    neither a workflow nor an action still produces a valid analysis.
- **Status:** advisory. Deliberately not a required check — gating merge on it
    would let a single CRITICAL false positive or a transient CodeQL infra flake
    wedge every PR; the merge gate is the in-tree workflow lints plus the zizmor
    pre-commit hook, re-run in the required `flake-check` job, with CodeQL as
    the deeper dataflow second opinion.

### octoscan

- **Unique signal:** repo-jacking and known-vuln (CVE) detection in `uses:`
    references, plus a second injection-triangulation angle — coverage zizmor
    and codeql do not provide.
- **Triggers:** a pre-commit hook on every commit that touches a workflow
    YAML under `.github/workflows/`, scanning the full directory rather
    than the staged files to match the CI invocation (it self-skips
    inside the Nix build sandbox, where docker is unavailable); PR to
    `main` filtered to
    `.github/workflows/**` and the octoscan scan script; push to `main`; weekly
    Friday cron (full tree); manual dispatch.
- **Status:** advisory by design. It is the cheapest scanner, but it fails
    on *any* finding (no severity threshold), so as a required check a
    single false positive would block merge. Its rule set is narrowed only
    by the suppression set in `scripts/octoscan-scan.sh` — two disabled
    rules (`local-action`, `dangerous-write`) and a single `--ignore` regex
    carrying two alternatives, each with its rationale in that script's
    header.
    Promotion would also force removing its PR paths filter. It stays
    advisory and path-filtered.
    - **Adding a suppression (operational):** a further rule or pattern is
        suppressed only for a confirmed false positive — three or more
        distinct occurrences, or one duplicating an existing zizmor or CodeQL
        finding one-to-one. Add it to `DISABLE_RULES` or `IGNORE_PATTERN` in
        `scripts/octoscan-scan.sh` (`--filter-triggers external` is a
        further lever the script leaves unused) and document it in that script's
        `Suppressions` header beside the flag it extends.

### scorecard

- **Unique signal:** OpenSSF Scorecard posture score — an independent second
    opinion on repo hardening (pinned dependencies, signed releases, SBOM,
    security policy, and more) that no in-tree lint computes as a
    single graded posture.
- **Triggers:** weekly Friday cron and manual dispatch only. It does **not**
    scan on PRs or pushes.
- **Status:** weekly watchdog. A check scoring anything below a
    perfect 10 (the policy is strict) — or a scorecard payload the
    threshold script cannot read as JSON at all — fails the run and
    opens a deduped `scorecard-drift` tracking issue; the next clean run
    closes it. The check set is curated — review-flow checks not applicable to a
    solo repo, checks duplicating an in-tree signal whether blocking or
    advisory, and checks no in-repo change can move, are dropped; the
    scorecard drift-check workflow file carries the per-check rationale.

### zizmor

- **Unique signal:** GitHub-Actions-specific static analysis
    (template-injection, excessive permissions, dangerous triggers) tuned to
    Actions semantics.
- **Triggers:** runs as a **pre-commit hook on every commit that touches a
    workflow YAML under `.github/workflows/`** (`--min-severity=low`,
    scanning the changed workflow files), plus a weekly Friday cron and
    manual dispatch. The hook also runs server-side on every PR and push:
    the required `flake-check` job runs `nix flake check`, which builds
    `checks.pre-commit`, and the zizmor hook carries no sandbox bail
    (unlike octoscan), so it re-scans `.github/workflows/` there too.
- **Status:** commit-time prevention + PR/push detection (the `flake-check`
    re-run) + weekly watchdog. The drift-check re-runs the same lock-pinned
    scan against `main` on a schedule and pages a finding as a deduped
    `zizmor-drift` issue, closed on the next clean run; a rule change arrives
    with the `flake.lock` bump whose PR `flake-check` already re-scans in
    full.

## In-tree lints and posture watchdogs

Beyond the external scanners, a family of in-tree shell lints — pre-commit
hooks, required PR lint-group jobs, plus daily watchdog crons — enforce
specific workflow and posture invariants. Most
appear in the [enforcement matrix](enforcement-matrix.md) with their enforcer
script, pre-commit hook id, and CI job where one exists — some are enforced by
hook alone, and some are standalone workflows rather than member checks;
several also have narrative coverage
in [workflow hardening](workflow-hardening.md). This table is an index, not a
re-description.

Two rows below have no matrix row of their own. The matrix is generated
from the annotations in the [invariant index](../invariant-index.md), so
a lint earns a row only by being an invariant this repo declares.
`actionlint` is the upstream workflow linter, run as a pre-commit hook,
and `stale-pin-check` is a cron workflow; neither is a declared
invariant. Their nearest-named matrix rows cover different rules —
"actionlint embedded-linter pins" covers the `-shellcheck=` and
`-pyflakes=` wrapper pins,
and "Stale-pin failure attribution" is the notify-body reason split.

| Lint / watchdog              | Catches                                                                      |
| ---------------------------- | ---------------------------------------------------------------------------- |
| actionlint                   | workflow syntax, `run:`-block shellcheck, expression errors                  |
| actionlint-shellcheck-active | guards that actionlint's shellcheck integration stays enabled                |
| actionlint-pyflakes-active   | guards that actionlint's pyflakes integration stays enabled                  |
| uses-sha-pinned              | every `uses:` pinned to a full commit SHA or a `./` self-reference           |
| patch-tag-pins               | the patch-tag pin-comment convention on SHA pins                             |
| pin-diff-isolated            | pin bumps isolated to their own diff                                         |
| ratchet-pin-audit            | a publisher force-moving a tag to a new SHA after we pinned it (daily cron)  |
| stale-pin-check              | the linpeas upstream pin stalled >14d behind a newer upstream release (cron) |
| min-permissions              | least-privilege `permissions:` on every workflow and job                     |
| checkout-persist-credentials | `persist-credentials: false` on `actions/checkout`                           |
| pull-request-target-absent   | bans the dangerous `pull_request_target` trigger                             |
| workflow-concurrency         | top-level `concurrency.group` present                                        |
| workflow-on-branches         | explicit branch scoping on `on:` triggers                                    |
| nix-run-pinned               | every `nix` subcommand pinned through the flake, never bare `nixpkgs#`       |
| cosign-identity-pinned       | every `cosign verify*` subcommand pins identity and OIDC issuer              |
| manifest-digest-pinned       | multi-arch manifest sources pinned by digest, not tag                        |
| settings-posture-drift-check | repo settings vs. the expected hardened posture (daily cron)                 |

See the [enforcement matrix](enforcement-matrix.md) for the authoritative
enforcer/hook/CI mapping of every row that has one.

## Why the overlap is budgeted

Each layer's blind spot is another layer's core competency:

- Pre-commit is bypassable → PR/push and the weekly sweep re-check
    server-side.
- Pattern matchers miss dataflow → codeql does taint analysis.
- codeql and zizmor do not model repo-jacking or CVEs → octoscan does.
- Per-diff review misses slow drift → daily and weekly watchdogs catch it.
- In-tree lints check specific invariants → scorecard grades overall posture
    independently.

Trimming a layer because another "overlaps" removes a unique angle. Any such
change needs a
[security-review entry](https://github.com/rvenutolo/linPEAS-flake/blob/main/CONTRIBUTING.md#security-review-entries)
recording which vectors become uncovered.
