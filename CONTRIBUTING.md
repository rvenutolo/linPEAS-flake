# Contributing to linPEAS-flake

`linPEAS-flake` is a solo-maintained Nix flake that re-distributes the
upstream `peass-ng/PEASS-ng` `linpeas.sh` binary. External contributions
are welcome on the strict terms below; the supply-chain hardening
posture is non-negotiable.

## Before you open a PR

- Read [`docs/development/git.md`](docs/development/git.md) — branch
    naming, commit signing, Conventional Commits, merge-commit-only
    policy.
- Read [`SECURITY.md`](SECURITY.md) — SHA-pinning, attestation chain,
    bump credentials.
- Run `just verify` locally — runs the same script-based required
    checks CI does (sub-30-second bundle).

## Local development

```sh
nix develop           # drops you into the devShell with every tool CI uses
just                  # list recipes
just check            # nix flake check (formatting + pre-commit + derivation builds)
just fmt              # treefmt — prettier + nixfmt + shfmt + taplo + mdformat
just lint             # pre-commit run --all-files
just lint-links       # lychee on tracked markdown
just verify           # every script-based check + every .test.sh fixture
just bump             # manually refresh linpeas pin from upstream latest
```

## What CI gates on

Every PR must pass the required status checks before merge.
The canonical list of required checks lives in
[`docs/security/required-checks.md`](docs/security/required-checks.md).
Highlights:

- `commitlint`, `lint-pr-title` — Conventional Commits client- and
    server-side.
- `uses-sha-pinned` — every `uses:` is a full 40-hex SHA with a
    trailing `# vX.Y.Z` version comment.
- `flake-check`, `build-linpeas`, `image-smoke` —
    derivation health on x86_64 and aarch64.
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
    Commits.** PR title is independently linted by `pr-title-lint` and
    becomes the merge-commit subject.

See [`docs/development/git.md`](docs/development/git.md) for the full
walkthrough.

## Reporting a security issue

Do **NOT** open a public issue. Email the maintainer per the contact
detail in [`SECURITY.md`](SECURITY.md).
