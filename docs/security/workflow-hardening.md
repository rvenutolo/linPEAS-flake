# Workflow-hardening invariants

Per-job hardening rules enforced across every workflow in `.github/workflows/`. Most rules are locked in by a script lint, run as a member check of a batched lint group job (`lint-workflow-security`, `lint-script-hygiene`, or `lint-doc-invariants`) and as a pre-commit hook. A few differ: some are enforced by a standalone CI job (`setup-nix-required`), some by CI only with no hook (`test-reachable`), and some are convention-only with no automated enforcer (lean lint-shell routing). See the [enforcement matrix](enforcement-matrix.md) for the authoritative per-rule mapping.

See [workflow-scanner division of labor](workflow-scanners.md) for how these
in-tree lints fit the broader layered scanning model (pre-commit → PR/push →
weekly sweep → watchdog) alongside the external scanners.

## job-timeout-minutes

Every job declares an explicit `timeout-minutes` as a positive integer.

GitHub Actions defaults a job timeout to 6 hours. A hung job at that ceiling burns the runner budget and stalls the merge queue. Requiring an explicit per-job value bounds the blast radius of any wedge and forces a deliberate choice when a job is added.

Reusable-workflow callers (jobs that use `uses: ./.github/workflows/<file>.yml`) are exempt because `timeout-minutes` is not valid on that shape; the timeout belongs in the called workflow's jobs.

Enforced by `scripts/check-job-timeout-minutes.sh`. Wired as the `lint-workflow-security` CI job (member check `job-timeout-minutes`) and as a pre-commit hook.

## workflow-concurrency

Every workflow declares a top-level `concurrency:` block with a non-empty `group:`.

Without a concurrency group, cron pile-ups and back-to-back PR pushes can spawn parallel runs on the same ref. Beyond burning runner minutes on superseded work, parallel runs can race steps that touch shared remote state (`gh release create`, tag pushes, image manifest writes). Forcing every workflow to declare a group keeps each ref serialized to one in-flight run by default.

`cancel-in-progress` is not required by this lint; the group alone is the load-bearing setting. Pipelines that must run to completion once started (e.g., `release-on-bump.yml`) deliberately set `cancel-in-progress: false` so back-to-back triggers queue instead of cancelling.

Enforced by `scripts/check-workflow-concurrency.sh`. Wired as the `lint-workflow-security` CI job (member check `workflow-concurrency`) and as a pre-commit hook.

## checkout-persist-credentials

Every `actions/checkout` step sets `with.persist-credentials: false` (boolean, not string).

Without it, `actions/checkout` writes `GITHUB_TOKEN` into `.git/config` and leaves it on disk for the remainder of the job. Any later step in the same job — a third-party action, a misbehaving binary, a shell injection in a `run:` block — can read the token from the working tree and use its scopes. `persist-credentials: false` drops the credential after the initial clone/fetch, narrowing the blast radius of a compromised later step.

Boolean `false` is required; the string `"false"` does not satisfy `actions/checkout`'s parsing.

Enforced by `scripts/check-checkout-persist-credentials.sh`. Wired as the `lint-workflow-security` CI job (member check `checkout-persist-credentials`) and as a pre-commit hook.

## upload-artifact-strict

Every `actions/upload-artifact` step sets `with.if-no-files-found: error`.

The action's default is `warn`, which silently uploads an empty artifact when the `path:` glob matches nothing. That hides build-output drift: a broken path produces a green job with no artifact, and the consumer side only notices when something downstream goes missing — sometimes many runs later. `error` turns the path-mismatch into a hard upload failure, surfacing the bug at its source.

Enforced by `scripts/check-upload-artifact-strict.sh`. Wired as the `lint-workflow-security` CI job (member check `upload-artifact-strict`) and as a pre-commit hook.

## workflow-on-branches

Every workflow that declares `on.pull_request:` or `on.push:` sets `branches: [main]` exactly under that trigger. No wildcards, no implicit all-branches, no other branch names.

Without the allowlist, Actions fires the workflow on every branch — burning runner minutes on stale topic branches and attaching surprising status checks to refs nobody is watching. Workflows that only run on `schedule:`, `workflow_dispatch:`, or `workflow_call:` are unaffected; `pull_request_target:` is handled by a separate lint that forbids it outright.

Enforced by `scripts/check-workflow-on-branches.sh`. Wired as the `lint-workflow-security` CI job (member check `workflow-on-branches`) and as a pre-commit hook.

## pull-request-target-absent

No workflow uses the `pull_request_target` trigger.

`pull_request_target` runs the **base** ref's workflow definition with the full secret scope of the base repo. If the workflow then checks out the PR head (the common reason to use this trigger), an attacker's fork PR can introduce malicious code that the base-ref workflow runs with secret access — the canonical Actions privilege-escalation footgun.

This repo has no use for the trigger. The lint hard-fails any workflow that adopts it. Removing the ban requires deleting this script, its `pull-request-target-absent` member entry under `lint-workflow-security` in `.github/lint-groups.yml`, and the pre-commit hook.

Enforced by `scripts/check-pull-request-target-absent.sh`. Wired as the `lint-workflow-security` CI job (member check `pull-request-target-absent`) and as a pre-commit hook.

## auto-merge-decline-gate

Every workflow run-block that calls `gh pr merge` with `--auto` also carries the decline gate: a `gh pr view --json state` query and a `CLOSED|MERGED` arm that exits non-zero.

An auto-merging update workflow recreates a per-period branch and merges its PR unattended. Without inspecting PR state first, a re-run in the same period overwrites a PR the maintainer explicitly closed (declined) or one already merged — silently reversing a human decision in a no-review flow. The gate aborts non-zero on `CLOSED|MERGED` so the run fails and a failure issue is filed instead.

This protects only an explicitly closed or merged PR; routine PRs are unaffected, so the fully-automated update flow is preserved.

Enforced by `scripts/check-auto-merge-decline-gate.sh`. Wired as the `lint-workflow-security` CI job (member check `auto-merge-decline-gate`) and as a pre-commit hook.

## script-shebang-pipefail

Every file under `scripts/*.sh` starts with `#!/usr/bin/env bash` (exact first line) and contains `set -Eeuo pipefail` somewhere in the file.

A script that silently swallows a failure can corrupt `linpeas-pin.json`, skip a security check, or leave a stale build artifact behind. `set -Eeuo pipefail` plus a portable shebang are the hardening minimum: `-e` aborts on any command failure, `-E` propagates ERR traps into subshells, `-u` rejects unset variables, `-o pipefail` makes a pipeline fail when any stage fails (not just the last).

The lint accepts longer set lines (e.g. `set -Eeuo pipefail -x`) as long as the exact `-Eeuo pipefail` token is present.

Enforced by `scripts/check-script-shebang-pipefail.sh`. Wired as the `lint-script-hygiene` CI job (member check `script-shebang-pipefail`) and as a pre-commit hook.

## no-yq-procsub

No `scripts/*.sh` feeds a redirection from a yq process substitution — `done < <(yq eval '.x' "$f")` and its variants.

A process substitution's exit status is invisible to `set -Eeuo pipefail`: the substitution runs in its own subshell, and the shell only ever sees the exit status of the command the redirection feeds (here, the `while`/`done` loop itself), not `yq`'s. If `yq` fails to parse its input, the process substitution produces empty output, the loop simply runs zero iterations, and the calling check exits 0 as if the scan found nothing to flag — a fail-open silently masquerading as a clean pass.

The sanctioned idioms both make a `yq` parse failure abort loudly instead: capture `yq`'s output into a variable first (`hits="$(yq eval '.x' "$f")"`, then iterate with `<<<"${hits}"`) so `set -e` catches a non-zero `yq` exit before the loop ever runs; or, for NUL-delimited output that can't round-trip through `"$(...)"` (command substitution strips embedded NUL bytes), write to a temp file and iterate with `< "${tmp}"`.

The lint skips comment lines (lines whose first non-whitespace character is `#`) so a script is free to document the banned idiom by name — e.g. explaining why it uses the capture idiom instead — without tripping the check on its own documentation.

Enforced by `scripts/check-no-yq-procsub.sh`. Wired as the `lint-script-hygiene` CI job (member check `no-yq-procsub`) and as a pre-commit hook.

## script-has-test

Every `scripts/check-*.sh` has a matching `tests/check-*.test.sh`, and every `tests/check-*.test.sh` has a matching `scripts/check-*.sh`.

The check-lint family is held together by naming convention: each lint script ships next to a fixture-driven test harness that validates the script's spec. Without enforcement, a new lint can land without tests and silently rot. The bidirectional pairing forecloses that.

`check-jsonschema` is exempt: it's a thin wrapper around the upstream `check-jsonschema` tool plus a schema bundle, so there's no spec-driven behavior worth unit-testing. New exemptions require updating the `EXEMPT` list in the script and justifying the entry in its comment.

Enforced by `scripts/check-script-has-test.sh`. Wired as the `lint-script-hygiene` CI job (member check `script-has-test`) and as a pre-commit hook.

## test-runner reachability

Every `tests/*.test.sh` harness is executed by at least one runner, so the coverage it represents is real rather than latent.

`check-script-has-test` guarantees a test *file* exists for each script; it does not guarantee the test ever *runs*. A harness wired into no runner is a coverage no-op — a regression it would catch merges green while the pairing guard stays satisfied. This asserts every harness is reachable via one of four runners: the `HARNESSES` array in `scripts/run-harness-group.sh` (the `harness-group` job), the `tests/refresh-*.test.sh` glob in `scripts/run-doc-freshness.sh` (the `doc-freshness` job), a `.github/lint-groups.yml` member resolving to `tests/check-<name>.test.sh` (run by `scripts/run-lint-group.sh`), or a direct `tests/<x>.test.sh` invocation in a `.github/workflows/*.yml`.

The `EXEMPT` list in the script is empty: every harness must be wired to a runner. A genuinely manual-only harness would be listed there with a rationale.

Enforced by `scripts/check-test-reachable.sh`. Wired as the `lint-script-hygiene` CI job (member check `test-reachable`).

## harness assertion discrimination

Every harness scenario asserts a substring that appears in no sibling scenario's output, and every harness asserting against captured scenario output is wired to the gate that checks it.

A harness proves behavior by grepping one scenario's captured output for a substring. When that substring also appears in a sibling scenario's output — a banner the script prints on the nominal path as well as the failure path, say — the grep matches whether or not the asserted behavior exists, so the harness stays green against a script that never implements it and the regression it was written to catch merges unseen. The gate records each scenario's asserted substring alongside its captured output and, after the run, flags any substring that also occurs in a sibling's output. Scenarios asserting the same substring are mutually exempt, and two records over byte-identical output are treated as one observation of a single run rather than two scenarios a substring fails to separate — the census line reports the distinct-output count so that collapse stays visible. A harness wired to the gate that records nothing fails closed.

`harness_assert_exempt <substring> <other-scenario|*> <rationale>` registers a reviewed exception: the named form where one failure path emits no token another lacks, the `*` form for a banner a script prints across a whole outcome class. The rationale is mandatory so every weakening is reviewable. A harness that asserts produced artifact content — a rewritten workflow file, a generated doc — rather than captured scenario output is listed on the `EXEMPT` array in `tests/_harness_assert_wired.test.sh` with a rationale comment.

Enforced by `scripts/lib/harness-assert.sh`, which runs inside every wired harness, and by `tests/_harness_assert_wired.test.sh`, which asserts the wiring; both are reached by the `harness-group` CI job.

## manifest-reading hook watches nix/hooks

Every pre-commit hook whose script reads the Nix hook manifest (`nix eval .#devTooling.<system>.preCommitHooks`) includes `nix/hooks` in its `files` filter.

A freshness hook regenerates or validates a generated doc from the manifest. When its `files` filter omits `nix/hooks`, a commit that edits only a hook definition under `nix/hooks/*.nix` changes the manifest but does not re-trigger the hook on the per-changed-file `git commit` path, so a stale generated doc can be committed locally. The `--all-files` CI mirror still catches the drift, but the local fast-path defense is lost. Tying every manifest-reader's filter to `nix/hooks` keeps the local and CI paths in agreement.

The guard derives the manifest-reading scripts by content (`preCommitHooks` / `PRECOMMIT_HOOK_NAMES`), not a hardcoded list, then asserts each referencing hook's `files` filter contains `nix/hooks`. It fails loud if it finds zero manifest-reading hooks, catching a parser break from a hook-file reformat.

Enforced by `scripts/check-manifest-hook-watches-nix.sh`. Wired as the `lint-script-hygiene` CI job (member check `manifest-hook-watches-nix`) and as a pre-commit hook.

## freshness hook watches evaluated modules

Every pre-commit hook whose generator evaluates `devTooling.<system>.<attr>` names, in its `files` filter, every nix module that attribute is defined or transposed by.

A freshness hook regenerates a doc from an evaluated flake attribute and refuses a stale commit. Its `files` regex decides which changed paths re-trigger it on the per-changed-file `git commit` path. When the filter misses a module the generator evaluates, a commit touching only that module leaves the doc stale with the guard silent. The `--all-files` CI mirror still catches the drift, but the local fast-path defense is lost, so the gap surfaces late.

The required module set is derived rather than hardcoded: modules naming the evaluated attribute in non-comment nix source, plus one level of their relative imports, plus modules assigning `flake.devTooling` — the transposition every generator reads through. The second signal is what makes the derivation structural. A module that merely mentions an attribute in a comment is not thereby required, and a module that performs the transposition is required whether or not it names the attribute at all.

The guard is source-parsed rather than `nix eval`-ed: `files` and `entry` are literal in source, and `nix eval` is the known local-commit-path long pole. It fails loud if it finds no `devTooling`-evaluating generator, no hook running one, or an attribute with no defining module — each of which means the derivation broke rather than that the tree is clean.

Enforced by `scripts/check-freshness-hook-watches-modules.sh`. Wired as the `lint-script-hygiene` CI job (member check `freshness-hook-watches-modules`) and as a pre-commit hook.

## lean lint-shell routing

The batched invariant-lint groups are split across two devShells by closure cost. The light groups — `lint-workflow-security` and `lint-script-hygiene` — run in `devShells.lint`, whose tight closure realizes far faster in CI than the full author shell. `lint-doc-invariants` must stay on `devShells.default`: its `renovate-config-validator` check invokes the `renovate` binary, which pulls the heavy renovate closure that the lean shell deliberately omits. Moving `lint-doc-invariants` to `.#lint` would break that check; moving the light groups back to `.#default` would forfeit the realize saving. A new batched group belongs in `.#lint` only if every tool it needs is in `nix/devshell-lint.nix` `buildInputs`; otherwise it stays on `.#default`.

## lint-shell-tools

The `lint-workflow-security` and `lint-script-hygiene` invariant-lint groups run inside the lean `devShells.lint` shell, which carries only the tools those groups need (bash, coreutils, gnugrep, gnused, gawk, findutils, yq-go, jq, gh, git, shellcheck, shfmt, actionlint, check-jsonschema) rather than the full author toolchain. The lean shell trades realize cost for a tighter closure, so a tool dropped from its `buildInputs` would surface only as a cryptic mid-check failure deep inside one of the batched groups.

This guard asserts every required tool is present on `PATH`. Run inside `devShells.lint` it validates the lean shell directly; run inside `devShells.default` it confirms the default shell remains a superset. A dropped tool becomes a named `::error::` line instead of an opaque downstream crash. The expected-tool list must stay in sync with `nix/devshell-lint.nix` `buildInputs`.

Enforced by `scripts/check-lint-shell-tools.sh`. Wired as the `lint-script-hygiene` CI job (member check `lint-shell-tools`) and as a pre-commit hook.

## ci-job-in-summary

Every `jobs.<name>:` in `.github/workflows/ci.yml` either appears as a key in `docs/_data/ci-check-categories.yml` or is on the lint's `EXEMPT` list of auxiliary jobs deliberately not exposed as required status checks. `EXEMPT` is currently empty: every `ci.yml` job is mapped. Conversely, every key in the category map corresponds to a real `jobs.<name>:` in some workflow file under `.github/workflows/`.

`refresh-ci-summary.sh` already enforces parity between the category map and `docs/security/required-checks.md`. This lint adds the ci.yml ↔ categories check, so a new required job that ships without a category mapping fails the PR rather than landing and breaking the pre-commit summary regenerator on the next commit.

Adding a new ci.yml job that should be a required status check requires updating the categories map, the required-checks doc, and the protect-main ruleset (in-tree and live). Adding an auxiliary job requires only an `EXEMPT` entry justified in the script comment. The list is self-policed: an entry must name a real `ci.yml` job that has no category-map key, so it cannot rot into a name that exempts nothing while the lint stays green.

The `EXEMPT` list is also the ci-job exemption source for the enforcement matrix: `scripts/refresh-enforcement-matrix.sh` reads it through this script's `--print-exempt` mode, so one declaration serves both checks and they cannot disagree about which auxiliary jobs are expected to have no invariant behind them. `--print-exempt` prints one job name per line and exits 0; an empty list prints nothing, so exit status — not output length — is what says the list is readable. The generator treats any nonzero exit as fatal, so a dropped or renamed mode aborts the refresh instead of quietly widening the orphan-job check to every unmapped job.

Enforced by `scripts/check-ci-job-in-summary.sh`. Wired as the `lint-doc-invariants` CI job (member check `ci-job-in-summary`) and as a pre-commit hook.

## run-block-strict

Every block-scalar or newline-carrying `run:` block under `.github/workflows/*.yml` starts with `set -Eeuo pipefail` as its first non-blank, non-comment line.

Bash inside Actions `run:` blocks defaults to `-e` off. A failed command in the middle of a block that runs several commands silently continues, producing wrong results in security-critical jobs (release signing, attestation verify, pin write-back). The strict-mode prelude closes that gap.

The rule keys off YAML node style (`|`, `>`, and their chomping/indent variants) as well as newlines in the evaluated value. Newline presence alone under-detects: a folded scalar (`run: >-`) spells a `;`-separated command sequence across several source lines but folds to one newline-free string, so a block that plainly runs several commands would otherwise slip past the requirement.

Plain single-line `run:` invocations are exempt — they're already a single shell command whose exit status drives the step directly.

Enforced by `scripts/check-run-block-strict.sh`. Wired as the `lint-workflow-security` CI job (member check `run-block-strict`) and as a pre-commit hook.

## fork-guard-release

Every workflow job that holds a guard-required write scope includes a fork-guard `if:` clause containing `github.repository == 'rvenutolo/linPEAS-flake'`.

Guard-required write scopes are any of: `contents: write`, `packages: write`, `id-token: write`, `attestations: write`, `actions: write`. A fork that inherits these workflows can otherwise fire them under its own `GITHUB_TOKEN` (or repo-scoped secrets, if any were configured) — accidentally cutting a release, pushing to the fork's container registry, minting OIDC tokens, or (for `actions: write`) pruning/mutating the canonical repo's Actions cache namespace or cancelling its runs. The repository check pins execution to the canonical repo.

A job that mints a GitHub App installation token (via `actions/create-github-app-token`, or referencing `secrets.BUMP_APP_PRIVATE_KEY`) is likewise privileged despite declaring a read-only `GITHUB_TOKEN`: the App token carries its own write scopes, so the job can commit via the REST contents API, open pull requests, and enable auto-merge — all under the canonical repo's identity. Such a job must carry the same fork guard, otherwise a fork holding the App's private key as a secret could drive those writes against the canonical repo.

GitHub Actions `if:` is job-scoped (no workflow-level syntax), so every guard-required job must carry the guard in its own `if:` expression. Existing `if:` clauses are AND-ed with the repository check.

Enforced by `scripts/check-fork-guard-release.sh`. Wired as the `lint-workflow-security` CI job (member check `fork-guard-release`) and as a pre-commit hook.

## nix-run-pinned

No workflow, script, or shell-fenced documentation invokes `nix run nixpkgs#<pkg>` against the bare `nixpkgs` flake reference.

At runtime the bare `nixpkgs` resolves through the user's (or runner's) flake registry — not this repo's `flake.lock`. A step that calls `nix run nixpkgs#cosign` therefore pulls whatever nixpkgs commit the runner's registry happens to point at, bypassing the Renovate-pinned `nixpkgs` input in `flake.lock`. A malicious or compromised nixpkgs revision could ship a backdoored tool.

Allowed alternatives:

- `nix shell .#<pkg> --command <pkg> <args>` — uses this repo's own flake outputs, resolved via `flake.lock`. Requires the package to be exposed under `packages.<pkg>` by the flake (see `nix/packages.nix`).
- `nix run .#<pkg> -- <args>` — same.
- `nix run nixpkgs/<rev>#<pkg>` — explicit commit-pin (the lint matches the literal `nixpkgs#` token with no `/<rev>` between).

`cosign` is exposed under `packages.cosign` so `release-on-bump.yml` and `verify-latest-release.yml` can invoke it via the pinned shape. Future tools follow the same pattern.

Enforced by `scripts/check-nix-run-pinned.sh`. Wired as the `lint-workflow-security` CI job (member check `nix-run-pinned`) and as a pre-commit hook.

## setup-nix composite required

{% raw %}
Every workflow that installs Nix must do so via
`./.github/actions/setup-nix`, passing
`github-token: ${{ secrets.GITHUB_TOKEN }}`. Direct use of
`cachix/install-nix-action` from a workflow is forbidden.
{% endraw %}

**Why.** Unauthenticated `api.github.com` tarball fetches are capped
at ~60 requests/hour per source IP. GitHub Actions runner IPs are
shared across many concurrent jobs; under contention the cap is
exhausted and the API returns `HTTP 401 Bad credentials`, which
surfaces from `nix build` / `nix flake` as a flake-input fetch
failure. Passing `access-tokens = github.com=<token>` raises the
ceiling to ~1000/hour per token and eliminates the class.

**Enforcement.** `scripts/check-setup-nix-required.sh`, gated by the
`setup-nix-required` job in `.github/workflows/ci.yml`.
