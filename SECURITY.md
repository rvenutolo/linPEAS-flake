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

The weekly `verify-latest-release` cron additionally re-fetches the pinned
`linpeas.sh` URL and compares the SRI hash against the pin file, detecting
upstream tag replacement (intentional or compromise).

## Trust model and SLSA attestation semantics

Every release artifact (OCI image, pin file) carries a SLSA
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
captured at push time. Those push-time steps do **not** re-resolve the
published `:VERSION` and `:latest` manifest tags after manifest
publication to confirm they still point at those digests. A consumer who pulls by the
manifest tag and then verifies against the **arch-resolved** digest
(via `docker manifest inspect` or the `RepoDigests` value returned by
`docker inspect`) is protected. A consumer who trusts the manifest tag
implicitly — without resolving to the per-arch digest — is not. The
mitigation is the `verify manifest tags resolve to attested per-arch digests` step in `release-on-bump.yml`'s `verify` job, which re-fetches
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

`dockerhub-sync.yml` triggers on `release-on-bump` workflow_run completed-successfully (plus manual dispatch). It does NOT trigger on arbitrary README pushes. This narrows the `DOCKERHUB_TOKEN_DELETE` exposure window to release-time only.

The `workflow_run` trigger does not introduce a TOCTOU concern: `dockerhub-sync.yml` has no `contents: write` and only PATCHes Docker Hub repo metadata.

## Supply-chain posture monitoring

Several scheduled workflows track supply-chain hygiene independent of
the release pipeline — `codeql.yml`, `octoscan.yml`,
`image-cve-scan.yml`, `scorecard-drift-check.yml`, and
`zizmor-drift-check.yml` (full cron inventory in
[`docs/architecture/ci.md`](docs/architecture/ci.md)). The rest of this
section covers `codeql.yml`; the other four are inventoried there.

- **`codeql.yml`** scans GitHub Actions workflow definitions on PRs
    that touch `.github/workflows/` or `.github/actions/`, every push
    to `main`, and weekly. The analyze step passes `fail-on: critical`
    to `codeql-action/analyze`: a CRITICAL-severity finding fails the
    workflow, and a notify job opens a deduped issue under the
    `codeql-critical` label. An analyze failure that produced no
    finding (scan crash, runner breakage) files under `codeql-infra`
    instead, so transient infrastructure trouble is not paged as a
    security finding. Findings **below** CRITICAL are advisory: they
    upload to the Security tab without failing the workflow. A green
    CodeQL run therefore proves the scan completed with zero CRITICAL
    findings — **not** that zero findings exist. Closing the loop on
    sub-critical findings requires a maintainer to review the Security
    tab when a PR touches `.github/workflows/`. CodeQL complements
    (does not replace) the `zizmor` pre-commit hook and the
    SHA-pinning + `permissions:` discipline applied workflow-wide.

The `codeql.yml` workflow is not in branch protection's required-check
set, and must not be promoted while its PR trigger carries a `paths:`
filter (the `required-checks-no-paths` invariant forbids paths filters
on required workflows). A CodeQL infrastructure failure must not block
linpeas pin bumps; failure surfacing is via the deduped issues filed by
the notify jobs.

## Secrets

- `BUMP_APP_PRIVATE_KEY` / `vars.BUMP_APP_CLIENT_ID` — the
    `linpeas-flake-bumper` GitHub App's PEM private key and public client
    ID. Used by `update-linpeas.yml`, `update-flake-lock.yml`,
    `renovate-flake-lock-refresh.yml`, and `release-on-bump.yml` to open
    and auto-merge bump and changelog PRs.
    The App is installed only on this repository with `Contents: Read and write` and `Pull requests: Read and write` permissions. Installation
    tokens are minted per job by `actions/create-github-app-token`, live
    one hour, and revoke at job end. See
    [`docs/security/repo-config.md`](docs/security/repo-config.md) for
    the full credential model. Rotate on suspected compromise only.

- `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN_RW` / `DOCKERHUB_TOKEN_DELETE` — Docker Hub access tokens used by the release pipeline. The split limits blast radius:

    - `DOCKERHUB_TOKEN_RW` — Read, Write on `rvenutolo/linpeas`. Used ONLY by `release-on-bump.yml` (per-arch + manifest + verify jobs). Cannot delete tags. `verify-latest-release.yml` deliberately does NOT receive it — its Docker Hub attestation checks run anonymously/read-only, so a compromised step there cannot exfiltrate the push credential.
    - `DOCKERHUB_TOKEN_DELETE` — Read, Write, Delete on `rvenutolo/linpeas`. Used ONLY by `dockerhub-sync.yml` (`peter-evans/dockerhub-description` needs Delete to PATCH repo metadata).

    The `Delete` capability is required by the `peter-evans/dockerhub-description`
    action used in `dockerhub-sync.yml`, which calls the Docker Hub repo-metadata
    endpoint; a `Read, Write`-only PAT returns `403 Forbidden` on that endpoint.
    Rotation: on suspected compromise only —
    no calendar cadence. If compromise is suspected: revoke at
    <https://hub.docker.com/settings/security>, generate a replacement,
    update `gh secret set DOCKERHUB_TOKEN_RW --repo rvenutolo/linPEAS-flake` or
    `gh secret set DOCKERHUB_TOKEN_DELETE --repo rvenutolo/linPEAS-flake` as
    appropriate. Compromise blast radius: a `DOCKERHUB_TOKEN_RW` leak allows
    pushing new tags but not deleting existing ones; a `DOCKERHUB_TOKEN_DELETE`
    leak allows tag deletion in addition. Mitigation: consumers verify the
    SLSA attestation with `gh attestation verify`; mismatched attestation
    is the canonical detection signal.

## SBOM attestations

In addition to build-provenance attestations, each release carries SBOM
attestations (CycloneDX-JSON predicate, predicate-type `https://cyclonedx.org/bom`)
for each per-arch OCI image.
Verify with:

```bash
gh attestation verify oci://ghcr.io/rvenutolo/linpeas@<DIGEST> --repo rvenutolo/linPEAS-flake
```

`gh attestation verify` lists ALL attached attestations — the SBOM attestation
is the one with predicate-type `https://cyclonedx.org/bom`; the provenance
attestation carries `https://slsa.dev/provenance/v1`.

## Runner egress control (harden-runner, block mode)

`step-security/harden-runner` runs as the first step of every job in every workflow, with `egress-policy: block`. Each job declares an `allowed-endpoints:` allowlist scoped to the minimum outbound hosts it needs: a shared baseline (`api.github.com`, `github.com`, `objects.githubusercontent.com`, `cache.nixos.org`, `releases.nixos.org`) plus job-specific endpoints. Block mode drops any egress to a host outside the allowlist, so a compromised step cannot exfiltrate a credential (App token, Docker Hub PAT, signing key) to an attacker-controlled host. Rotating host families — Actions cache/artifact storage (`*.blob.core.windows.net`), the hosted-runner control plane (`*.githubapp.com`), and the Actions runtime (`*.actions.githubusercontent.com`) — are matched by wildcard.

When a job legitimately needs a new endpoint, add it to that job's `allowed-endpoints:`; never relax a job back to audit. `scripts/check-harden-runner-block.sh` (pre-commit and the `lint-workflow-security` CI job) fails any harden-runner step that is not `egress-policy: block` with a non-empty allowlist.

## Settings posture

Repository settings knobs the security model depends on (probe-verifiable from `docs/security/settings-posture.md`):

- `secret_scanning`, `secret_scanning_push_protection`, `dependabot_security_updates` all **enabled**.
- Actions: `sha_pinning_required: true`. Belt-and-braces against Renovate misconfiguration — every `uses:` must be SHA-pinned at GitHub level, not just by Renovate convention. Smoke-tested: unpinned `uses: actions/checkout@v4` was rejected by GitHub with "all actions must be pinned to a full-length commit SHA".
- Workflow tokens: `default_workflow_permissions: read`, `can_approve_pull_request_reviews: false`. Prevents a compromised workflow from self-approving a PR.
- `github-pages` environment: `can_admins_bypass: false`.
- Account: 2FA enabled on the maintainer account with non-SMS second factor (specifics not recorded).

Any drift on any of the above is treated as a security incident. The `docs/security/settings-posture.md` file is the source of truth and includes copy-pasteable probe commands.
