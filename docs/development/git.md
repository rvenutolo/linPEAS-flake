# Git workflow

How to commit, sign, and merge changes to `linPEAS-flake`.

## Branch naming

`type/description` in kebab-case. Allowed types (alphabetical):

- `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`,
    `revert`, `style`, `test`

Examples: `feat/add-arm64-image`, `fix/pin-url-prefix-check`,
`chore/bump-nixpkgs-unstable`.

## Commit signing

Every commit on `main` must be signed. The `required_signatures` rule is
enforced by the `protect-main` ruleset.

- **Branch commits** sign locally via your SSH or GPG key. Configure once:
    `git config commit.gpgsign true` (and set `user.signingkey`).
- **Bot commits** originate from REST `PUT /repos/{owner}/{repo}/contents/{path}`
    authenticated as the `linpeas-flake-bumper` GitHub App. GitHub web-flow-signs
    every such commit.

## Conventional Commits

Every branch commit must independently satisfy
[Conventional Commits](https://www.conventionalcommits.org). Enforced by:

- `commitlint` — required check; runs per commit on a PR.
- `lint-pr-title` (workflow `pr-title-lint`) — required check; runs against
    the PR title.

### How the merge commit is composed

GitHub writes the merge-commit message, not the author. The subject is the PR
title (`merge_commit_title=PR_TITLE`) with `" (#<number>)"` appended. The body
is the PR body (`merge_commit_message=PR_BODY`), **rewrapped at 72 columns**,
with fenced code blocks left exactly as written.

That rewrap decides where each rule can be enforced:

- **Subject rules** are checked by `lint-pr-title`, which lints the title with
    the `" (#<number>)"` suffix attached — the composed string, not the bare
    title. A title that fits the header limit on its own can still overflow it
    once the suffix lands, and that failure would appear only on `main`, on a
    commit no longer amendable.
- **Spelling** is checked by the same `lint-pr-title` step, with `typos`
    against that same composed string. The PR title becomes the merge-commit
    subject, and `git-cliff` renders merge subjects into `CHANGELOG.md`; a
    typo frozen into that immutable, signed subject can only be corrected by
    a render-time rewrite, so the title is spell-checked in CI before the
    merge makes it permanent.
- **Body and footer line length** is checked by `commitlint` on the
    `pull_request` event, against hand-authored branch commits, where the author
    controls the wrapping.
- **Body and footer line length is not checked on the merge commit.** No author
    wrote those lines. Prose is already wrapped to 72 columns by GitHub, so a
    line can exceed the limit only where GitHub declined to rewrap — inside a
    code fence, in a table row, or in a single over-long token — all content
    that must not be wrapped. The `commitlint` job therefore lints `push` to
    `main` with `.commitlintrc.merge.yml`, which names the same base preset
    as `.commitlintrc.yml` and disables `body-max-line-length` and
    `footer-max-line-length`. It names the base preset directly rather than
    extending `.commitlintrc.yml` by relative path, so a resolution failure
    cannot first surface on `main` after a merge; a second `commitlint` step
    also loads it on `pull_request` purely to prove the action can read it
    while the file is still amendable.

Both configs must be named explicitly via the action's `configFile` input. The
input defaults to a file this repo does not have, and the action then falls back
to a bundled `@commitlint/config-conventional`, so an unset `configFile` makes
the repo's own config a no-op with no visible symptom.
`scripts/check-commitlint-config-explicit.sh` pins that shut, along with the
two configs' agreement on the base preset they extend.

A PR body may contain fenced lines of any length. Prose in a PR body needs no
manual wrapping — GitHub wraps it.

Allowed types match branch naming. Append `!` after the type for breaking
changes: `feat!: drop x86_64-darwin from declared systems`.

## Local lint commands

These commands need no manual tool install — `just`, `pre-commit`, `lychee`,
and every linter come from the flake `devShells.default`. Enter it with
`nix develop` or via direnv (`direnv allow`). See the README Development
section for details.

Run before pushing:

```sh
just verify      # lint groups + harnesses + doc-freshness + standalone enforcers (what CI runs)
just check       # nix flake check
just fmt         # nix fmt (treefmt: shfmt, prettier, …)
just lint        # pre-commit run --all-files
just lint-links  # lychee link check (inputs in the recipe, exclusions in lychee.toml)
```

Entering the devShell — `nix develop` or direnv — wires the git hooks for
you, so the same hooks run against staged files on every commit. To run
them against every file in the repo instead, use `just lint`. Only when
working outside the devShell do you need to install them yourself, once:

```sh
pre-commit install
```

## Merge policy

**Merge-commit only.** Enforced repo-wide
(`allow_merge_commit=true`, `allow_rebase_merge=false`,
`allow_squash_merge=false`) AND by the `protect-main` ruleset
(`pull_request.allowed_merge_methods=["merge"]`).

Why: rebase and squash rewrite commits and break signatures.
Merge-commit preserves each branch commit verbatim (with its existing
signature) and adds a web-flow-signed merge commit on top.

Clean a branch with `git rebase --interactive <base>` before opening
the PR. Don't leak WIP commits onto `main`.

## Pre-commit hooks

Hooks (alphabetical):

<!-- BEGIN precommit-table -->

| Hook                             | What it checks                                                                                                                                           |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `actionlint`                     | GitHub Actions workflow syntax (shellcheck pinned).                                                                                                      |
| `actionlint-pyflakes-active`     | actionlint pyflakes integration canary.                                                                                                                  |
| `actionlint-shellcheck-active`   | actionlint shellcheck integration canary.                                                                                                                |
| `auto-merge-decline-gate`        | Auto-merge run-blocks carry the CLOSED/MERGED decline gate.                                                                                              |
| `bump-script-integrity`          | scripts/bump-linpeas.sh keeps its URL-prefix, .digest, and atomic-write guards.                                                                          |
| `check-cron-table`               | Cron schedule table + ordering paragraph in docs/architecture/ci.md matches workflow cron triggers.                                                      |
| `check-doc-anchors`              | Every markdown #anchor link resolves to a heading slug in its target file.                                                                               |
| `check-doc-cron-restatement`     | Docs outside ci.md must link the cron schedule table, not restate literal workflow times.                                                                |
| `check-ephemeral-refs`           | Markdown prose and shell/Nix/YAML comments carry no ephemeral references (PR/issue refs, prose dates, planning/review labels, literal .claude/ paths).   |
| `check-jsonschema`               | Schema-shape validation of repo config (renovate.json, workflows, actions).                                                                              |
| `check-orphan-invariants`        | Every docs/ file has an invariant-index entry and vice versa.                                                                                            |
| `checkout-persist-credentials`   | Every actions/checkout sets with.persist-credentials: false.                                                                                             |
| `ci-dag-fresh`                   | docs/architecture/ci-dag.md matches .github/workflows/ci.yml needs graph.                                                                                |
| `ci-job-in-summary`              | ci.yml jobs cross-checked against docs/\_data/ci-check-categories.yml.                                                                                   |
| `ci-summary-fresh`               | README CI summary matches required-checks.md and the category map.                                                                                       |
| `commitlint`                     | Commit message satisfies Conventional Commits (CI parity via .commitlintrc.yml).                                                                         |
| `commitlint-config-explicit`     | Every commitlint action step names an existing configFile; merge ruleset stays minimal.                                                                  |
| `cosign-identity-pinned`         | cosign verify\* pins --certificate-identity[-regexp] + --certificate-oidc-issuer.                                                                        |
| `deadnix`                        | Unused Nix bindings.                                                                                                                                     |
| `editorconfig-checker`           | .editorconfig compliance (charset, line endings, trailing whitespace, final newline).                                                                    |
| `egress-allowlist`               | Every job's allowed-endpoints list matches its tool inventory and carries no denylisted host.                                                            |
| `enforcement-matrix-fresh`       | docs/security/enforcement-matrix.md matches the annotated invariant index and real enforcers.                                                            |
| `ephemeral-refs-gap-fresh`       | The scope-gap block in docs/development/linting.md matches the file types no ephemeral-refs extractor claims, and none of them carries a blocking shape. |
| `flake-show-fresh`               | flake-show block in docs/reference/flake-outputs.md matches current flake outputs.                                                                       |
| `fork-guard-release`             | Release-grade jobs include github.repository fork guard.                                                                                                 |
| `freshness-hook-watches-modules` | Every flake-evaluating freshness hook watches every source its evaluation reads.                                                                         |
| `gh-api-version-header`          | Every gh api / api.github.com call in scripts passes an X-GitHub-Api-Version header.                                                                     |
| `gh-attestation-repo`            | gh attestation verify pins --repo rvenutolo/linPEAS-flake.                                                                                               |
| `harden-runner-block`            | Every harden-runner step uses egress-policy: block with non-empty allowed-endpoints.                                                                     |
| `harden-runner-first`            | Every workflow job's first step is step-security/harden-runner.                                                                                          |
| `harness-assert-wired`           | Every output-asserting tests/\*.test.sh is wired to the discrimination gate.                                                                             |
| `job-timeout-minutes`            | Every workflow job declares an explicit timeout-minutes.                                                                                                 |
| `just-recipes-fresh`             | just-recipes blocks in README.md and docs/reference/just-recipes.md match the justfile.                                                                  |
| `lint-shell-tools`               | devShells.lint declares every tool the .#lint lint groups need.                                                                                          |
| `lock-derived-docs`              | Every lock-writing workflow regenerates the docs a lock bump can make stale.                                                                             |
| `manifest-digest-pinned`         | docker manifest/imagetools create sources are digest-pinned.                                                                                             |
| `manifest-hook-watches-nix`      | Every hook reaching the Nix hook manifest watches nix/hooks in its files filter.                                                                         |
| `markdownlint`                   | Markdown style + structure.                                                                                                                              |
| `min-permissions`                | Top-level workflow permissions empty; each job declares its own scopes.                                                                                  |
| `nix-run-pinned`                 | No unpinned nix run nixpkgs#<pkg>; use nix shell .#<pkg> or pin a rev.                                                                                   |
| `nixfmt`                         | Nix file formatting.                                                                                                                                     |
| `nixpkgs-hammering`              | nixpkgs idiom checker for the linpeas derivation.                                                                                                        |
| `no-opaque-procsub`              | No scripts/\*.sh feeds a redirection from a process substitution.                                                                                        |
| `octoscan`                       | synacktiv/octoscan workflow vulnerability scanner.                                                                                                       |
| `patch-tag-pins`                 | SHA-pinned uses: comments name exact patch tag (vX.Y.Z), not major (vX).                                                                                 |
| `permission-scopes`              | Per-job GITHUB_TOKEN write scopes are allowlisted in .github/permission-scopes.yml.                                                                      |
| `pin-diff-isolated`              | Only scripts/bump-linpeas.sh mutates linpeas-pin.json.                                                                                                   |
| `pin-parity-fresh`               | The pin-parity block in docs/architecture/auto-update.md names every tracked file carrying the canonical pin-shape regex.                                |
| `pre-commit-hooks-sha-parity`    | The pre-commit-hooks input SHA in flake.nix matches flake.lock locked.rev.                                                                               |
| `precommit-table-fresh`          | Hook table in docs/development/git.md matches the flake hook manifest.                                                                                   |
| `pull-request-target-absent`     | No workflow uses the pull_request_target trigger.                                                                                                        |
| `renovate-config-validator`      | Validate renovate.json against the upstream Renovate config schema.                                                                                      |
| `run-block-strict`               | Block-scalar and newline-carrying run: blocks in workflows and composite actions start with set -Eeuo pipefail.                                          |
| `script-has-test`                | Every scripts/check-*.sh paired with tests/check-*.test.sh.                                                                                              |
| `script-shebang-pipefail`        | Every scripts/\*.sh has portable shebang + set -Eeuo pipefail.                                                                                           |
| `scripts-reference-fresh`        | docs/reference/scripts.md matches in-script annotations.                                                                                                 |
| `shellcheck`                     | Shell-script static analysis.                                                                                                                            |
| `size-label-ignores`             | The size-label ignore list matches what the generators declare they write.                                                                               |
| `statix`                         | Nix anti-pattern lint.                                                                                                                                   |
| `test-harnesses-fresh`           | The harness census in docs/reference/test-harnesses.md matches the harnesses in tests/.                                                                  |
| `treefmt`                        | Multi-language formatter aggregator (shfmt, prettier, etc).                                                                                              |
| `treefmt-config-fresh`           | treefmt-config block in docs/reference/treefmt-config.md matches the evaluated treefmt config.                                                           |
| `typos`                          | Spell-check across the repo.                                                                                                                             |
| `upload-artifact-strict`         | Every actions/upload-artifact sets with.if-no-files-found: error.                                                                                        |
| `uses-sha-pinned`                | Every uses: reference is SHA-pinned.                                                                                                                     |
| `verify-reason-ladder`           | Every verify-job step id is mapped to a documented reason token, in execution order.                                                                     |
| `workflow-concurrency`           | Every workflow declares a top-level concurrency.group.                                                                                                   |
| `workflow-on-branches`           | pull_request: and push: declare branches: [main] explicitly.                                                                                             |
| `yamllint`                       | YAML style.                                                                                                                                              |
| `zizmor`                         | GitHub Actions security audit.                                                                                                                           |

<!-- END precommit-table -->

Lychee is not a pre-commit hook (it hits the network and can flake on
offline work). Run it manually with `just lint-links`; CI runs it on a
weekly cron only (plus manual `workflow_dispatch`); it is not a required
check.
