# Verification walkthrough

Step-by-step procedure to verify a release of this wrapper. None of this trusts the Pages site you are reading.

## Tools needed

- `gh` (GitHub CLI) ≥ 2.40 — `gh attestation verify` subcommand.
- `curl` — for direct asset download.
- `sha256sum` and/or `openssl` — for hash recomputation.
- `nix` (optional) — for SRI hash recompute.

## 1. Verify the OCI image's build provenance

```bash
gh attestation verify \
  oci://ghcr.io/rvenutolo/linpeas:{{ dashboard.release.latest_tag or "<tag>" }} \
  --repo rvenutolo/linPEAS-flake
```

Same trust model: proves the image was built by this repo's release workflow.

## Multi-arch attestations

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

## 2. Verify the daily parity check is current

```bash
gh run list \
  --workflow verify-latest-release.yml \
  --repo rvenutolo/linPEAS-flake \
  --limit 1 \
  --json conclusion,updatedAt,url
```

Look for `"conclusion": "success"` within the last 24-25 hours. Current state on the Pages site: **{{ dashboard.parity.conclusion }}** at {{ dashboard.parity.checked_at }}.

## Bump-script integrity guards

`scripts/bump-linpeas.sh`:

- Asset URL must start with
    `https://github.com/peass-ng/PEASS-ng/releases/download/`. Hard fail.
- GitHub-API `.digest` field never silently skipped. Absent or
    non-`sha256:` prefix is a hard fail.
- Pin file written via `mktemp` + `mv` (atomic). Never `>`.
- Every `gh api` call must pass `--header "X-GitHub-Api-Version: 2022-11-28"`.
    Apply to any new security-sensitive GitHub-REST caller.

## verify-latest-release upstream parity

Daily verify cron re-fetches the pinned `linpeas.sh` URL, recomputes the SRI
hash via `openssl dgst -sha256 -binary | base64 --wrap=0`, compares against
`linpeas-pin.json`. Failure = security incident.

## verify-latest-release failure attribution

`verify-latest-release.yml`'s notify body distinguishes failure
reasons via per-step `id:` outcomes mapped to a `reason` token by
the `attribute failure reason` step. Reasons:

- `upstream-sri-drift` — **security incident.** Upstream
    `linpeas.sh` SHA-256 no longer matches the pinned SRI.
- `manifest-tag-drift` — `:latest` no longer resolves to the same
    manifest as `:VERSION` on ghcr.io or docker.io.
- `ghcr-attest-failed` / `hub-attest-failed` /
    `pin-attest-failed` — attestation
    verification failed for a specific artifact.
- `release-tag-fetch-failed` / `release-asset-download-failed` —
    transient GitHub API / asset visibility lag.
- `unknown` — attribution step couldn't match a known failed step
    (bug in the attribute logic itself).

Only `upstream-sri-drift` (and to a lesser extent `manifest-tag-drift`)
warrant the "treat as security incident" framing. Folding all reasons
into a single failure body trains the maintainer to skim-read auto-filed
issues — exactly the wrong reflex when the failure is a real SRI drift.

This pattern is the project default for every cron-notify caller: each
must attribute distinct failure reasons to distinct issue-body wording.
Alert fatigue is a security risk.

## Gitleaks secret scanning

`gitleaks.yml` scans the full git history (`fetch-depth: 0`) on push to
main, every PR, and a weekly cron (Mon 13:00 UTC). Required check named
`gitleaks` in the `protect-main` ruleset.

- Uses only `secrets.GITHUB_TOKEN` — PR-triggered workflow secret
    allowlist invariant holds.
- New leaked-secret finding = security incident. Triage:
    rotate → purge with `git filter-repo` → force-push (admin bypass).
- Vendor `gitleaks/*` is in the `allowed_actions` allowlist; do not
    remove without replacing the workflow.

## Dependency review

`dependency-review.yml` runs on every PR via
`actions/dependency-review-action`. Required check named
`dependency-review`. `fail-on-severity: moderate`,
`comment-summary-in-pr: on-failure`.

- Repo has no traditional package manifests today; the action mostly scans `.github/workflows/**` `uses:` against the GitHub Advisory DB + license policy. Belt-and-braces backup to SHA-pinning + Renovate + zizmor.
- If a future PR adds a real manifest (npm/cargo/pip/etc.), the action
    begins scanning it without any workflow change.

## OCI image CVE scan (Trivy)

`ci.yml`'s `image-cve-scan` job uploads SARIF (CRITICAL + HIGH) to
code-scanning, then post-processes the SARIF to count CRITICAL findings
and **fails the job** when count > 0. On push to main, an
`image-cve-scan-notify` follow-on job (`needs: image-cve-scan`,
`if: failure() + event_name=='push'`) opens / updates a deduped issue
via `notify-workflow-result` (label: `image-cve-critical`).

- NOT in required-checks (intentional — `update-flake-lock` must still
    land even if a CVE is present, with explicit maintainer awareness).
- Trivy's own `exit-code: "0"` + `ignore-unfixed: true` intentional;
    the CRITICAL-fail decision lives in the `fail on CRITICAL findings`
    step so the SARIF upload always runs.
- Prevention path: nixpkgs auto-bump via `update-flake-lock`. CRITICAL
    finding → bump nixpkgs, then rebuild the OCI image.
- CRITICAL threshold is hardcoded to CVSS `>= 9.0` per GitHub's current
    Code Scanning mapping. The `jq tonumber? // 0` guard drops non-numeric
    SARIF severities (e.g. textual `"high"` from some scanners) instead
    of erroring under `set -euo pipefail`. Revisit the threshold if
    GitHub revises the CVSS-to-bucket mapping.

## SBOM attestation

`release-on-bump.yml` generates SPDX-JSON SBOMs via `anchore/sbom-action`,
attests via `actions/attest-sbom`.

- Per-arch image SBOMs: attested + pushed to ghcr.io and docker.io with
    `push-to-registry: true`. NOT release assets.
- `verify-latest-release.yml`'s `gh attestation verify` covers SBOMs
    automatically (verifies ALL attestations).

## Cosign keyless signatures

In addition to `actions/attest-build-provenance` + `actions/attest-sbom`
(verifiable via `gh attestation verify`), `release-on-bump.yml` signs
every published image digest with Sigstore cosign in keyless mode.
Signatures are minted with an ephemeral Fulcio cert issued against the
workflow's OIDC token, then recorded in Rekor.

Signed artifacts per release:

- **Per-arch images**: `cosign sign <reg>/rvenutolo/linpeas@<digest>` on
    both `ghcr.io` and `docker.io`. The signature lands as a `.sig` tag
    next to each image in each registry.
- **Multi-arch index**: same `cosign sign` invocation against the OCI
    index digest of `:VERSION` (which equals the digest of `:latest`,
    since they reference identical bytes). One signature per registry
    covers both tags.

### Identity pinning

Verification must pin both:

- `--certificate-identity https://github.com/rvenutolo/linPEAS-flake/.github/workflows/release-on-bump.yml@refs/heads/main`
- `--certificate-oidc-issuer https://token.actions.githubusercontent.com`

A signature minted by any other workflow, branch ref, or OIDC issuer
fails verification. The release pipeline's `verify` job and the daily
`verify-latest-release.yml` cron both enforce these exact values.

### User-facing verification commands

Image (any tag or digest works; both registries are signed):

```bash
cosign verify \
  --certificate-identity 'https://github.com/rvenutolo/linPEAS-flake/.github/workflows/release-on-bump.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  ghcr.io/rvenutolo/linpeas:latest
```

No `gh` CLI required. Pairs with the existing `gh attestation verify`
path — pick whichever toolchain fits the consumer's pipeline.
