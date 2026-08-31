# Contributing to linPEAS-flake

`linPEAS-flake` is a solo-maintained Nix flake that wraps the upstream
`peass-ng/PEASS-ng` `linpeas.sh` script and republishes it as a Nix
package and OCI image. External contributions
are welcome on the strict terms below; the supply-chain hardening
posture is non-negotiable.

## Before you open a PR

- Read [`docs/development/git.md`](docs/development/git.md) — branch
    naming, commit signing, Conventional Commits, merge-commit-only
    policy.
- Read [`SECURITY.md`](SECURITY.md) — SHA-pinning, attestation chain,
    bump credentials.
- Run `just verify` locally — runs the batched lint groups, harnesses,
    doc-freshness checks, and standalone enforcers CI runs. Hook-only lints
    run under `just lint`. Two enforcers in the recipe
    (`check-tag-protection.sh`, `check-protect-main.sh`) probe the upstream
    repo's live rulesets over the GitHub API and need an authenticated `gh`;
    on a fork or without `gh auth login` they report could-not-run (exit 2)
    and fail the recipe while everything else still runs.

## Local development

```sh
nix develop           # drops you into the devShell with every tool CI uses
just                  # list recipes
just check            # nix flake check (formatting + pre-commit + lint-shell-tools + derivation build)
just fmt              # treefmt — prettier + nixfmt + shfmt + taplo + mdformat + just
just lint             # pre-commit run --all-files
just lint-links       # lychee over every markdown file lychee.toml does not exclude
just verify           # lint groups + harnesses + doc-freshness + standalone enforcers
just bump             # manually refresh linpeas pin from upstream latest
```

## What CI gates on

Every PR must pass 29 required status checks before merge.
The canonical list of required checks lives in
[`docs/security/required-checks.md`](docs/security/required-checks.md).
Highlights:

- `commitlint`, `lint-pr-title` — Conventional Commits client- and
    server-side.
- `lint-workflow-security` — batched workflow-security lints; e.g.
    member check `uses-sha-pinned`: every non-local `uses:` is a full
    40-hex SHA (path-relative `./…` composite refs excepted).
    The trailing `# vX.Y.Z` patch-tag comment is a separate rule,
    `patch-tag-pins`, which belongs to no lint group and therefore runs
    against the tree as a pre-commit hook only; no required check
    enforces it. Its test harness does run in CI, inside
    `harness-group`.
- `flake-check`; `build-linpeas`(`-arm64`), `smoke-test`(`-arm64`),
    `image-smoke`(`-arm64`) — derivation health on x86_64 and aarch64.
- `gitleaks`, `dependency-review` — supply-chain.
- `pr-workflows-no-secrets`, `required-checks-no-paths`,
    `renovate-invariants`, `tag-protection-drift-check` — invariant
    lints.

## Merge policy

- **Merge-commit only.** No squash, no rebase. Enforced repo-wide and
    by the `protect-main` ruleset.
- **All commits on `main` must be signed** (`required_signatures`).
    Branch commits sign locally via SSH or GPG; bot commits originate
    from REST `PUT /contents` calls authenticated as the
    `linpeas-flake-bumper` App and are web-flow-signed by GitHub.
- **Every branch commit must independently satisfy Conventional
    Commits.** PR title is independently linted by `lint-pr-title` and
    becomes the merge-commit subject.

See [`docs/development/git.md`](docs/development/git.md) for the full
walkthrough.

## Reporting a security issue

Do **NOT** open a public issue. Email the maintainer per the contact
detail in [`SECURITY.md`](SECURITY.md).
