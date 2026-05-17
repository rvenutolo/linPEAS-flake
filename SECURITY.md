# Security Policy

## Reporting issues in this flake wrapper

If you find a security issue in the **flake wrapper itself** (the Nix code,
GitHub Actions workflows, helper scripts, or release-publishing automation in
this repo), please email <venutolo@hotmail.com>. Do not open a public issue.

## Reporting issues in LinPEAS itself

This repo is a thin Nix-flake wrapper around upstream
[peass-ng/PEASS-ng](https://github.com/peass-ng/PEASS-ng). It does not
modify `linpeas.sh`. Vulnerabilities in LinPEAS itself should be reported
upstream via the PEASS-ng project's reporting channels.

## Verification

The pinned `linpeas.sh` is recorded in `linpeas-pin.json` with an SRI
hash. `nix build` will refuse to build if the downloaded blob does not
match. The auto-update workflow additionally cross-checks the GitHub
Releases API `digest` field on each bump (hard fail if absent — never a
silent skip). Upstream PEASS-ng releases ship no signatures (GPG, cosign,
SLSA, etc.), so all integrity rests on the pinned hash plus trust in
GitHub's hosting.

The daily `verify-latest-release` cron additionally re-fetches the pinned
`linpeas.sh` URL and compares the SRI hash against the pin file, detecting
upstream tag replacement (intentional or compromise).

## Trust model and SLSA attestation semantics

Every release artifact (bundle, OCI image, pin file) carries a SLSA
build-provenance attestation, verifiable with
`gh attestation verify <artifact> --repo rvenutolo/linPEAS-flake`. These
attestations prove **build provenance**: the published artifact was
produced by this repository's release workflow at the recorded commit
SHA. They do **not** prove **content trust**: this wrapper repo does not
review, audit, or otherwise vet upstream `linpeas.sh` content before
publishing it.

If you require content review, do not consume releases automatically.
Read the upstream release notes, inspect the script, and pin to a
known-good version manually.

### Multi-arch attestations

The published OCI image is a multi-arch manifest covering `linux/amd64`
and `linux/arm64`. **SLSA attestations are per-arch**, not per-manifest.
This means:

- `gh attestation verify oci://docker.io/rvenutolo/linpeas:<tag>` may
  not resolve cleanly against the manifest index alone — point the verify
  at the arch-specific image (or pull on the target arch and use the
  resolved `RepoDigests` value).
- Each arch image was independently built from the same commit of this
  repo, so the attestations cover the same source provenance.
- The manifest index itself is **not** attested. An attacker with push
  to either registry could repoint the manifest at unattested images;
  the verify step in `release-on-bump.yml` would catch this at release
  time, but consumers who only verify the manifest pointer (not the
  arch image) would miss it. Always verify against the resolved
  arch-image digest.

The release pipeline's `verify` job validates the per-arch digests
captured at push time. It does **not** re-resolve the published
`:VERSION` and `:latest` manifest tags after manifest publication to
confirm they still point at those digests. A consumer who pulls by the
manifest tag and then verifies against the **arch-resolved** digest
(via `docker manifest inspect` or the `RepoDigests` value returned by
`docker inspect`) is protected. A consumer who trusts the manifest tag
implicitly — without resolving to the per-arch digest — is not. The
mitigation now in place is the `manifest-tag-reresolve` step in
`release-on-bump.yml` (added as part of SC-POST-2), which re-fetches
both `:VERSION` and `:latest` manifests post-publish and confirms
their per-arch digests match the values that were attested. A drift
at this step fails the release.

## Auto-merge surface

Three independent automations merge to `main` without human review:

- `update-linpeas.yml` (daily) — upstream `linpeas.sh` content.
- `update-flake-lock.yml` (weekly) — `nixpkgs` and other flake input revs.
- Renovate (weekly) — GitHub Action SHAs and the pinned Nix installer
  version.

Each is gated by CI (build success + SRI-hash integrity), not by content
review. A compromise of any upstream feed produces an attested release
within roughly 24 hours of upstream doing it. This is the documented and
accepted trust model for a thin wrapper repo — it matches the trust model
of `curl ... | bash`, with the addition of reproducible, hash-pinned
downloads and build-provenance attestations.

## Supply-chain posture monitoring

One scheduled workflow tracks supply-chain hygiene independent of the
release pipeline. It uploads findings to the Security tab; it is not
in branch protection's required-check set for content-policy reasons
documented below.

- **`codeql.yml`** scans GitHub Actions workflow definitions on every
  PR, push to `main`, and weekly. **Findings are advisory.** The
  workflow does not pass `fail-on:` to `codeql-action/analyze`, so a
  high-severity finding uploads to the Security tab but does **not**
  fail the workflow. A green CodeQL run therefore proves that the
  scan completed, **not** that zero findings exist. Treating
  "CodeQL green" as evidence of workflow safety is a misreading.
  Closing the loop on findings requires a maintainer to review the
  Security tab when a PR touches `.github/workflows/`. CodeQL
  complements (does not replace) the `zizmor` pre-commit hook and
  the SHA-pinning + `permissions:` discipline applied workflow-wide.

The `codeql.yml` workflow is not in branch protection's required-check set. A CodeQL infrastructure failure must not block linpeas pin bumps; failure surfacing is via the standard GitHub email channel.

## Secrets

- `BUMP_PAT` — fine-grained personal access token used by
  `update-linpeas.yml` and `update-flake-lock.yml` to open and auto-merge
  bump PRs. Required scopes: this repository only, with `contents: write`
  and `pull-requests: write`. Rotate annually (or on suspected
  compromise). Stored as a repository secret.
- `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` — Docker Hub access token
  used by `release-on-bump.yml` to mirror the OCI image to
  `docker.io/rvenutolo/linpeas` and by `dockerhub-sync.yml` to
  refresh the repo README. Token scope is `Read, Write, Delete`
  on the `rvenutolo/linpeas` repository only — **not** account-admin
  or org-admin. The `Delete` capability is required by the
  `peter-evans/dockerhub-description` action used in
  `dockerhub-sync.yml`, which calls the Docker Hub repo-metadata
  endpoint; a `Read, Write`-only PAT returns `403 Forbidden` on
  that endpoint (verified empirically 2026-05-17). Rotation: on
  suspected compromise only — no calendar cadence. If compromise
  is suspected: revoke at
  <https://hub.docker.com/settings/security>, generate a replacement,
  update `gh secret set DOCKERHUB_TOKEN --repo rvenutolo/linPEAS-flake`.
  Compromise blast radius: attacker can push arbitrary tags to
  `docker.io/rvenutolo/linpeas`. Mitigation: consumers verify the
  SLSA attestation with `gh attestation verify`; mismatched attestation
  is the canonical detection signal.

## SBOM attestations

In addition to build-provenance attestations, each release carries SBOM
attestations (SPDX-JSON predicate, predicate-type `https://spdx.dev/Document`)
for the bundle and each per-arch OCI image (P4.2 / GAP-12, 2026-05-17).
Verify with:

```bash
gh attestation verify linpeas-bundle.sh --repo rvenutolo/linPEAS-flake
gh attestation verify oci://ghcr.io/rvenutolo/linpeas@<DIGEST> --repo rvenutolo/linPEAS-flake
```

`gh attestation verify` lists ALL attached attestations — the SBOM attestation
is the one with predicate-type `https://spdx.dev/Document`; the provenance
attestation carries `https://slsa.dev/provenance/v1`.

The bundle SBOM is also published as a release asset
(`linpeas-bundle.sbom.spdx.json`) for consumers who want to ingest it directly
without verifying the attestation.

## Settings posture

Repository settings knobs the security model depends on (probe-verifiable from `docs/security/settings-posture.md`):

- `secret_scanning`, `secret_scanning_push_protection`, `dependabot_security_updates` all **enabled**. `secret_scanning_non_provider_patterns` and `secret_scanning_validity_checks` are shown as `disabled` in the GitHub API but cannot be flipped via the REST API for personal accounts — they appear to require GitHub Advanced Security or a UI toggle not exposed programmatically. Documented as a residual gap (GAP-1 / GAP-2 partially addressed 2026-05-17, P1).
- Actions: `sha_pinning_required: true` (added 2026-05-17, P1, GAP-3). Belt-and-braces against Renovate misconfiguration — every `uses:` must be SHA-pinned at GitHub level, not just by Renovate convention. Smoke-tested: unpinned `uses: actions/checkout@v4` was rejected by GitHub with "all actions must be pinned to a full-length commit SHA".
- Workflow tokens: `default_workflow_permissions: read`, `can_approve_pull_request_reviews: false` (added 2026-05-17, P1, GAP-6). Prevents a compromised workflow from self-approving a PR.
- `github-pages` environment: `can_admins_bypass: false` (added 2026-05-17, P1, GAP-10).
- Account: 2FA enabled on the maintainer account, verified 2026-05-17 with non-SMS second factor (specifics not recorded) (P1, GAP-15).

Any drift on any of the above is treated as a security incident. The `docs/security/settings-posture.md` file is the source of truth and includes copy-pasteable probe commands.
