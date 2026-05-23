# Invariant index

Binding rules of the project. Each entry points to the tracked doc
that holds the canonical wording for that rule. Linted by
`scripts/check-orphan-invariants.sh` — every entry here must resolve
to an existing file under `docs/`, and every `docs/**/*.md` (minus
an explicit EXEMPT allowlist for overview pages) must appear here.

Behavior rules for the AI assistant and other non-binding guidance
live in `.claude/CLAUDE.md` (untracked).

## Security

- **Workflow SHA pinning** — every `uses:` SHA-pinned. → [security/repo-config.md](security/repo-config.md)
- **Renovate invariants** — pinDigests, minimumReleaseAge, no top-level automerge. → [security/repo-config.md](security/repo-config.md)
- **Tag-protection ruleset** — `release-tag-protection`, drift-check lint. → [security/repo-config.md](security/repo-config.md)
- **Allowed-actions allowlist** — vendor list canonical; drift = incident. → [security/allowed-actions.md](security/allowed-actions.md)
- **Bump-script integrity** — URL prefix, `.digest`, atomic write, API-version header. → [security/verification.md](security/verification.md)
- **verify-latest-release parity + attribution** — SRI drift = incident; per-reason notify bodies. → [security/verification.md](security/verification.md)
- **Gitleaks / Dependency review / Trivy / SBOM** — required-check details + thresholds. → [security/verification.md](security/verification.md)
- **Cosign keyless signing + identity pinning** — per-arch + multi-arch index signed; verify must pin workflow ref + OIDC issuer. → [security/verification.md](security/verification.md)
- **Bump credentials blast-radius** — GitHub App, no PAT, no `git push`. → [security/trust-model.md](security/trust-model.md)
- **PR-triggered workflow secret allowlist** — only `secrets.GITHUB_TOKEN`. → [security/trust-model.md](security/trust-model.md)
- **harden-runner** — first step in every job. → [security/trust-model.md](security/trust-model.md)
- **GITHUB_TOKEN min-permissions** — top-level `permissions: {}`; every job declares own scopes. → [security/min-permissions.md](security/min-permissions.md)
- **protect-main ruleset** — in-tree mirror + drift-check. → [security/required-checks.md](security/required-checks.md)
- **Repo-settings posture** — three binding flags. → [security/settings-posture.md](security/settings-posture.md)

## Architecture / CI

- **Pin-diff isolation** — only `bump-linpeas.sh` mutates `linpeas-pin.json`. → [architecture/auto-update.md](architecture/auto-update.md)
- **flake.nix pin invariants** — `pin.version` regex, `pin.url` prefix. → [architecture/auto-update.md](architecture/auto-update.md)
- **Release VERSION shape** — `[A-Za-z0-9._/-]+`. → [architecture/auto-update.md](architecture/auto-update.md)
- **Linpeas-pin release-trigger** — pin change must cut release. → [architecture/auto-update.md](architecture/auto-update.md)
- **Stale-pin attribution / cron-notify root-cause / dockerhub-sync trigger / Pages invariants / Cron schedule** → [architecture/ci.md](architecture/ci.md)
- **update-flake-lock credential split / renovate-flake-lock-refresh** → [architecture/flake-input-bumps.md](architecture/flake-input-bumps.md)

## Install / Runbooks

- **OCI image** — `Entrypoint` not `Cmd`; bash+coreutils set. → [install/docker.md](install/docker.md)
- **Manifest digest-pinning** — `buildx imagetools create` uses `@sha256:`. → [install/docker.md](install/docker.md)
- **DOCKERHUB_TOKEN split** — `_RW` vs `_DELETE`, never unsuffixed. → [runbooks/dockerhub-recovery.md](runbooks/dockerhub-recovery.md)
- **Docker Hub notify-body parity** — issue body mirrors runbook. → [runbooks/dockerhub-recovery.md](runbooks/dockerhub-recovery.md)
- **settings-drift-checker App scope** — dedicated read-only App for admin-scoped settings probes; isolates blast radius from GITHUB_TOKEN and the bump App. → [runbooks/settings-drift-app.md](runbooks/settings-drift-app.md)

## Development

- **ci-summary-category-map** — every required status check is categorized for the README CI summary. → [security/required-checks.md](security/required-checks.md).
- **Merging PRs** — merge-commit only, signed, PR title = subject. → [development/git.md](development/git.md)
- **Treefmt YAML quote gotcha / README flake-show auto-block** → [development/linting.md](development/linting.md)
- **PR auto-labeling** → [development/labeling.md](development/labeling.md)
