# Invariant index

Binding rules of the project. Each entry points to the tracked doc
that holds the canonical wording for that rule. Linted by
`scripts/check-orphan-invariants.sh` — every entry here must resolve
to an existing file under `docs/`, and every `docs/**/*.md` (minus
an explicit EXEMPT allowlist for overview pages) must appear here.

Behavior rules for the AI assistant and other non-binding guidance
live in `.claude/CLAUDE.md` (untracked).

## Security

- **Workflow SHA pinning** — every `uses:` SHA-pinned. → [security/repo-config.md](security/repo-config.md) <!-- enforcer: scripts/check-uses-sha-pinned.sh; ci: uses-sha-pinned; hook: uses-sha-pinned -->
- **Renovate invariants** — pinDigests, minimumReleaseAge, no top-level automerge. → [security/repo-config.md](security/repo-config.md) <!-- enforcer: scripts/check-renovate-invariants.sh; scripts/check-renovate-config-validator.sh; ci: renovate-invariants; renovate-config-validator; hook: renovate-config-validator -->
- **Tag-protection ruleset** — `release-tag-protection`, drift-check lint. → [security/repo-config.md](security/repo-config.md) <!-- enforcer: scripts/check-tag-protection.sh; ci: tag-protection-drift-check; hook: - -->
- **Allowed-actions allowlist** — vendor list canonical; drift = incident. → [security/allowed-actions.md](security/allowed-actions.md) <!-- enforcer: scripts/check-allowed-actions-api.sh; ci: allowed-actions-api-harness; hook: - -->
- **Bump-script integrity** — URL prefix, `.digest`, atomic write, API-version header. → [security/verification.md](security/verification.md) <!-- enforcer: scripts/check-gh-api-version-header.sh; ci: gh-api-version-header; hook: gh-api-version-header -->
- **verify-latest-release parity + attribution** — SRI drift = incident; per-reason notify bodies. → [security/verification.md](security/verification.md) <!-- enforcer: -; ci: -; hook: - -->
- **Gitleaks / Dependency review / Trivy / SBOM** — required-check details + thresholds. → [security/verification.md](security/verification.md) <!-- enforcer: -; ci: -; hook: - -->
- **Cosign keyless signing + identity pinning** — per-arch + multi-arch index signed; verify must pin workflow ref + OIDC issuer. → [security/verification.md](security/verification.md) <!-- enforcer: scripts/check-cosign-identity-pinned.sh; ci: cosign-identity-pinned; hook: cosign-identity-pinned -->
- **gh attestation verify --repo pin** — every `gh attestation verify` invocation passes `--repo rvenutolo/linPEAS-flake`. → [security/verification.md](security/verification.md) <!-- enforcer: scripts/check-gh-attestation-repo.sh; ci: gh-attestation-repo; hook: gh-attestation-repo -->
- **cosign verify identity + issuer pin** — every `cosign verify` pins `--certificate-identity[-regexp]` AND `--certificate-oidc-issuer`. → [security/verification.md](security/verification.md) <!-- enforcer: scripts/check-cosign-identity-pinned.sh; ci: cosign-identity-pinned; hook: cosign-identity-pinned -->
- **Bump credentials blast-radius** — GitHub App, no PAT, no `git push`. → [security/trust-model.md](security/trust-model.md) <!-- enforcer: -; ci: -; hook: - -->
- **PR-triggered workflow secret allowlist** — only `secrets.GITHUB_TOKEN`. → [security/trust-model.md](security/trust-model.md) <!-- enforcer: scripts/check-pr-workflows-no-secrets.sh; ci: pr-workflows-no-secrets; hook: - -->
- **harden-runner** — first step in every job. → [security/trust-model.md](security/trust-model.md) <!-- enforcer: scripts/check-harden-runner-first.sh; ci: harden-runner-first; hook: harden-runner-first -->
- **Per-job timeout-minutes** — every job declares explicit `timeout-minutes`. → [security/workflow-hardening.md](security/workflow-hardening.md) <!-- enforcer: scripts/check-job-timeout-minutes.sh; ci: job-timeout-minutes; hook: job-timeout-minutes -->
- **Workflow concurrency group** — every workflow declares top-level `concurrency.group`. → [security/workflow-hardening.md](security/workflow-hardening.md) <!-- enforcer: scripts/check-workflow-concurrency.sh; ci: workflow-concurrency; hook: workflow-concurrency -->
- **Checkout persist-credentials false** — every `actions/checkout` step sets `persist-credentials: false`. → [security/workflow-hardening.md](security/workflow-hardening.md) <!-- enforcer: scripts/check-checkout-persist-credentials.sh; ci: checkout-persist-credentials; hook: checkout-persist-credentials -->
- **upload-artifact strict** — every `actions/upload-artifact` step sets `if-no-files-found: error`. → [security/workflow-hardening.md](security/workflow-hardening.md) <!-- enforcer: scripts/check-upload-artifact-strict.sh; ci: upload-artifact-strict; hook: upload-artifact-strict -->
- **Workflow on.branches main-only** — every `pull_request:`/`push:` trigger declares `branches: [main]` exactly. → [security/workflow-hardening.md](security/workflow-hardening.md) <!-- enforcer: scripts/check-workflow-on-branches.sh; ci: workflow-on-branches; hook: workflow-on-branches -->
- **pull_request_target forbidden** — no workflow uses the `pull_request_target` trigger. → [security/workflow-hardening.md](security/workflow-hardening.md) <!-- enforcer: scripts/check-pull-request-target-absent.sh; ci: pull-request-target-absent; hook: pull-request-target-absent -->
- **scripts/\*.sh shebang + pipefail** — every script under `scripts/` starts with `#!/usr/bin/env bash` and uses `set -Eeuo pipefail`. → [security/workflow-hardening.md](security/workflow-hardening.md) <!-- enforcer: scripts/check-script-shebang-pipefail.sh; ci: script-shebang-pipefail; hook: script-shebang-pipefail -->
- **check-script ↔ test pairing** — every `scripts/check-*.sh` has a matching `tests/check-*.test.sh` and vice versa. → [security/workflow-hardening.md](security/workflow-hardening.md) <!-- enforcer: scripts/check-script-has-test.sh; ci: script-has-test; hook: script-has-test -->
- **ci.yml job ↔ summary category** — every required ci.yml job appears in `ci-check-categories.yml`; every category entry points at a real job. → [security/workflow-hardening.md](security/workflow-hardening.md) <!-- enforcer: scripts/check-ci-job-in-summary.sh; ci: ci-job-in-summary; hook: ci-job-in-summary -->
- **Multi-line run: strict-mode prelude** — every multi-line `run:` block starts with `set -Eeuo pipefail`. → [security/workflow-hardening.md](security/workflow-hardening.md) <!-- enforcer: scripts/check-run-block-strict.sh; ci: run-block-strict; hook: run-block-strict -->
- **Fork-guard on release-grade jobs** — every job with write-scope perms includes `github.repository == 'rvenutolo/linPEAS-flake'` in its `if:`. → [security/workflow-hardening.md](security/workflow-hardening.md) <!-- enforcer: scripts/check-fork-guard-release.sh; ci: fork-guard-release; hook: fork-guard-release -->
- **No unpinned `nix run nixpkgs#`** — must use `nix shell .#<pkg>`, `nix run .#<pkg>`, or pin a revision. → [security/workflow-hardening.md](security/workflow-hardening.md) <!-- enforcer: scripts/check-nix-run-pinned.sh; ci: nix-run-pinned; hook: nix-run-pinned -->
- **setup-nix composite required** — workflows install Nix only via .github/actions/setup-nix with github-token. → [security/workflow-hardening.md](security/workflow-hardening.md) <!-- enforcer: scripts/check-setup-nix-required.sh; ci: setup-nix-required; hook: - -->
- **GITHUB_TOKEN min-permissions** — top-level `permissions: {}`; every job declares own scopes. → [security/min-permissions.md](security/min-permissions.md) <!-- enforcer: scripts/check-min-permissions.sh; ci: min-permissions; hook: min-permissions -->
- **protect-main ruleset** — in-tree mirror + drift-check. → [security/required-checks.md](security/required-checks.md) <!-- enforcer: scripts/check-protect-main.sh; ci: protect-main-drift-check; hook: - -->
- **Repo-settings posture** — three binding flags. → [security/settings-posture.md](security/settings-posture.md) <!-- enforcer: scripts/check-settings-posture.sh; ci: settings-posture-harness; hook: - -->

## Architecture / CI

- **Pin-diff isolation** — only `bump-linpeas.sh` mutates `linpeas-pin.json`. → [architecture/auto-update.md](architecture/auto-update.md) <!-- enforcer: scripts/check-pin-diff-isolated.sh; ci: pin-diff-isolated; hook: pin-diff-isolated -->
- **flake.nix pin invariants** — `pin.version` regex, `pin.url` prefix. → [architecture/auto-update.md](architecture/auto-update.md) <!-- enforcer: -; ci: -; hook: - -->
- **Release VERSION shape** — `[A-Za-z0-9._/-]+`. → [architecture/auto-update.md](architecture/auto-update.md) <!-- enforcer: -; ci: -; hook: - -->
- **Linpeas-pin release-trigger** — pin change must cut release. → [architecture/auto-update.md](architecture/auto-update.md) <!-- enforcer: -; ci: -; hook: - -->
- **Stale-pin attribution / cron-notify root-cause / dockerhub-sync trigger / Pages invariants / Cron schedule** → [architecture/ci.md](architecture/ci.md) <!-- enforcer: -; ci: -; hook: - -->
- **update-flake-lock credential split / renovate-flake-lock-refresh** → [architecture/flake-input-bumps.md](architecture/flake-input-bumps.md) <!-- enforcer: -; ci: -; hook: - -->

## Install / Runbooks

- **OCI image** — `Entrypoint` not `Cmd`; bash+coreutils set. → [install/docker.md](install/docker.md) <!-- enforcer: -; ci: -; hook: - -->
- **Manifest digest-pinning** — `buildx imagetools create` uses `@sha256:`. → [install/docker.md](install/docker.md) <!-- enforcer: -; ci: -; hook: - -->
- **DOCKERHUB_TOKEN split** — `_RW` vs `_DELETE`, never unsuffixed. → [runbooks/dockerhub-recovery.md](runbooks/dockerhub-recovery.md) <!-- enforcer: -; ci: -; hook: - -->
- **Docker Hub notify-body parity** — issue body mirrors runbook. → [runbooks/dockerhub-recovery.md](runbooks/dockerhub-recovery.md) <!-- enforcer: -; ci: -; hook: - -->
- **settings-drift-checker App scope** — dedicated read-only App for admin-scoped settings probes; isolates blast radius from GITHUB_TOKEN and the bump App. → [runbooks/settings-drift-app.md](runbooks/settings-drift-app.md) <!-- enforcer: -; ci: -; hook: - -->

## Development

- **ci-summary-category-map** — every required status check is categorized for the README CI summary. → [security/required-checks.md](security/required-checks.md). <!-- enforcer: scripts/check-ci-job-in-summary.sh; scripts/refresh-ci-summary.sh; ci: ci-job-in-summary; refresh-ci-summary-test; hook: ci-job-in-summary; ci-summary-fresh -->
- **Merging PRs** — merge-commit only, signed, PR title = subject. → [development/git.md](development/git.md) <!-- enforcer: -; ci: -; hook: commitlint -->
- **Treefmt YAML quote gotcha / flake-show auto-block** → [development/linting.md](development/linting.md) <!-- enforcer: scripts/refresh-flake-show.sh; ci: -; hook: treefmt; flake-show-fresh -->
- **Flake outputs reference** — auto-regenerated `nix flake show --all-systems` tree; do not hand-edit. → [reference/flake-outputs.md](reference/flake-outputs.md) <!-- enforcer: scripts/refresh-flake-show.sh; ci: -; hook: flake-show-fresh -->
- **PR auto-labeling** → [development/labeling.md](development/labeling.md) <!-- enforcer: -; ci: -; hook: - -->
