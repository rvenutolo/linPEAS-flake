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

| Hook                      | What it checks                                                                                                                  |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `actionlint`              | GitHub Actions workflow syntax.                                                                                                 |
| `commitizen`              | Commit message satisfies Conventional Commits (local parity with the CI `commitlint` job).                                      |
| `deadnix`                 | Unused Nix bindings.                                                                                                            |
| `editorconfig-checker`    | `.editorconfig` compliance (charset, line endings, trailing whitespace, final newline).                                         |
| `markdownlint`            | Markdown style + structure (mirrors the CI `markdownlint` job).                                                                 |
| `nixpkgs-fmt`             | Nix file formatting.                                                                                                            |
| `readme-flake-show-fresh` | `README.md` `flake-show` block matches current flake outputs (guarded with `NIX_BUILD_TOP` so it skips inside the Nix sandbox). |
| `shellcheck`              | Shell-script static analysis.                                                                                                   |
| `statix`                  | Nix anti-pattern lint.                                                                                                          |
| `treefmt`                 | Multi-language formatter aggregator (covers `shfmt`, `prettier`, etc).                                                          |
| `typos`                   | Spell-check across the repo.                                                                                                    |
| `uses-sha-pinned`         | Every `uses:` is SHA-pinned (guarded with `NIX_BUILD_TOP`).                                                                     |
| `yamllint`                | YAML style.                                                                                                                     |
| `zizmor`                  | GitHub Actions security audit.                                                                                                  |

Lychee is not a pre-commit hook (it hits the network and can flake on
offline work). Run it manually with `just lint-links`; CI runs it on a
weekly cron and as a PR check.

One-time setup:

```sh
pre-commit install
```
