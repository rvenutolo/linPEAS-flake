# Git workflow

How to commit, sign, and merge changes to `linPEAS-flake`.

## Branch naming

`type/description` in kebab-case. Allowed types (alphabetical):

- `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`,
    `revert`, `style`, `test`

Examples: `feat/add-lz4-support`, `fix/s3-retry-timeout`,
`chore/update-quarkus-bom`.

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

The PR title becomes the merge-commit subject (`merge_commit_title=PR_TITLE`);
the PR body becomes the merge-commit body (`merge_commit_message=PR_BODY`).

Allowed types match branch naming. Append `!` after the type for breaking
changes: `feat!: drop Java 11 support`.

## Local lint commands

Run before pushing:

These commands need no manual tool install — `just`, `pre-commit`, `lychee`,
and every linter come from the flake `devShells.default`. Enter it with
`nix develop` or via direnv (`direnv allow`). See the README Development
section for details.

```sh
just check       # nix flake check
just fmt         # nix fmt (treefmt: shfmt, prettier, …)
just lint        # pre-commit run --all-files
just lint-links  # lychee link check on tracked markdown
```

`pre-commit install` (once) wires git hooks so `just lint` runs
automatically on commit.

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

| Hook                           | What it checks                                                                        |
| ------------------------------ | ------------------------------------------------------------------------------------- |
| `actionlint`                   | GitHub Actions workflow syntax.                                                       |
| `check-doc-anchors`            | Every markdown #anchor link resolves to a heading slug in its target file.            |
| `check-jsonschema`             | Schema-shape validation of repo config (renovate.json, workflows, actions).           |
| `check-orphan-invariants`      | Every docs/ file has an invariant-index entry and vice versa.                         |
| `checkout-persist-credentials` | Every actions/checkout sets with.persist-credentials: false.                          |
| `ci-job-in-summary`            | ci.yml jobs cross-checked against docs/\_data/ci-check-categories.yml.                |
| `ci-summary-fresh`             | README CI summary matches required-checks.md and the category map.                    |
| `commitlint`                   | Commit message satisfies Conventional Commits (CI parity via .commitlintrc.yml).      |
| `cosign-identity-pinned`       | cosign verify pins --certificate-identity[-regexp] + --certificate-oidc-issuer.       |
| `deadnix`                      | Unused Nix bindings.                                                                  |
| `editorconfig-checker`         | .editorconfig compliance (charset, line endings, trailing whitespace, final newline). |
| `flake-show-fresh`             | flake-show block in docs/reference/flake-outputs.md matches current flake outputs.    |
| `fork-guard-release`           | Release-grade jobs include github.repository fork guard.                              |
| `gh-api-version-header`        | Every gh api / api.github.com call in scripts passes an X-GitHub-Api-Version header.  |
| `gh-attestation-repo`          | gh attestation verify pins --repo rvenutolo/linPEAS-flake.                            |
| `harden-runner-first`          | Every workflow job's first step is step-security/harden-runner.                       |
| `job-timeout-minutes`          | Every workflow job declares an explicit timeout-minutes.                              |
| `just-recipes-fresh`           | README just-recipes block matches the justfile.                                       |
| `markdownlint`                 | Markdown style + structure.                                                           |
| `min-permissions`              | Top-level workflow permissions empty; each job declares its own scopes.               |
| `nix-run-pinned`               | No unpinned nix run nixpkgs#<pkg>; use nix shell .#<pkg> or pin a rev.                |
| `nixfmt-rfc-style`             | Nix file formatting.                                                                  |
| `pin-diff-isolated`            | Only scripts/bump-linpeas.sh mutates linpeas-pin.json.                                |
| `pre-commit-hooks-sha-parity`  | The pre-commit-hooks input SHA in flake.nix matches flake.lock locked.rev.            |
| `precommit-table-fresh`        | Hook table in docs/development/git.md matches the flake hook manifest.                |
| `pull-request-target-absent`   | No workflow uses the pull_request_target trigger.                                     |
| `run-block-strict`             | Multi-line run: blocks start with set -Eeuo pipefail.                                 |
| `script-has-test`              | Every scripts/check-*.sh paired with tests/check-*.test.sh.                           |
| `script-shebang-pipefail`      | Every scripts/\*.sh has portable shebang + set -Eeuo pipefail.                        |
| `shellcheck`                   | Shell-script static analysis.                                                         |
| `statix`                       | Nix anti-pattern lint.                                                                |
| `treefmt`                      | Multi-language formatter aggregator (shfmt, prettier, etc).                           |
| `typos`                        | Spell-check across the repo.                                                          |
| `upload-artifact-strict`       | Every actions/upload-artifact sets with.if-no-files-found: error.                     |
| `uses-sha-pinned`              | Every uses: reference is SHA-pinned.                                                  |
| `workflow-concurrency`         | Every workflow declares a top-level concurrency.group.                                |
| `workflow-on-branches`         | pull_request: and push: declare branches: [main] explicitly.                          |
| `yamllint`                     | YAML style.                                                                           |
| `zizmor`                       | GitHub Actions security audit.                                                        |

<!-- END precommit-table -->

Lychee is not a pre-commit hook (it hits the network and can flake on
offline work). Run it manually with `just lint-links`; CI runs it on a
weekly cron and as a PR check.

One-time setup:

```sh
pre-commit install
```
