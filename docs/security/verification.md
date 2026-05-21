# Verification walkthrough

Step-by-step procedure to verify a release of this wrapper. None of this trusts the Pages site you are reading.

## Tools needed

- `gh` (GitHub CLI) ≥ 2.40 — `gh attestation verify` subcommand.
- `curl` — for direct asset download.
- `sha256sum` and/or `openssl` — for hash recomputation.
- `nix` (optional) — for SRI hash recompute.

## 1. Verify the bundle's build provenance

```bash
curl --location \
  https://github.com/rvenutolo/linPEAS-flake/releases/download/{{ dashboard.release.latest_tag or "<tag>" }}/linpeas-bundle.sh \
  --output linpeas-bundle.sh

gh attestation verify linpeas-bundle.sh --repo rvenutolo/linPEAS-flake
```

Expected output ends with:

```text
Loaded digest sha256:... for file://linpeas-bundle.sh
Verified attestation against GitHub's keyless signing flow.
Successfully verified ...
```

This proves the bundle was produced by `release-on-bump.yml` in this repo. It does **not** prove the bundle equals upstream `linpeas.sh`.

## 2. Verify the OCI image's build provenance

```bash
gh attestation verify \
  oci://ghcr.io/rvenutolo/linpeas:{{ dashboard.release.latest_tag or "<tag>" }} \
  --repo rvenutolo/linPEAS-flake
```

Same trust model: proves the image was built by this repo's release workflow.

## 3. Cross-check the bundle against upstream

The bundle is `linpeas.sh` with line 1 rewritten. To verify content equivalence:

```bash
# Get this repo's pin
PIN_URL=$(curl --silent https://raw.githubusercontent.com/rvenutolo/linPEAS-flake/main/linpeas-pin.json | jq --raw-output .url)
PIN_HASH=$(curl --silent https://raw.githubusercontent.com/rvenutolo/linPEAS-flake/main/linpeas-pin.json | jq --raw-output .hash)
echo "Pin URL:  $PIN_URL"
echo "Pin hash: $PIN_HASH"

# Download upstream
curl --location "$PIN_URL" --output upstream-linpeas.sh

# Compute SRI hash and compare
COMPUTED=$(nix hash file --sri upstream-linpeas.sh)
test "$PIN_HASH" = "$COMPUTED" && echo "OK" || echo "MISMATCH"

# Diff line 1 only
diff <(sed -n '2,$p' linpeas-bundle.sh) <(sed -n '2,$p' upstream-linpeas.sh)
```

Expected: hash matches, and the diff is empty for lines 2 onward. (Line 1 differs intentionally: `#!/usr/bin/env bash` in the bundle, `#!/bin/sh` in upstream.)

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

## 4. Verify the daily parity check is current

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
    `bundle-attest-failed` / `pin-attest-failed` — attestation
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

- Bundle SBOM: attached to release as `linpeas-bundle.sbom.spdx.json`,
    attested.
- Per-arch image SBOMs: attested + pushed to ghcr.io and docker.io with
    `push-to-registry: true`. NOT release assets.
- `verify-latest-release.yml`'s `gh attestation verify` covers SBOMs
    automatically (verifies ALL attestations).

## SBOM diff in release notes

After the bundle SBOM is generated and attested, the `bundle` job in
`release-on-bump.yml` downloads the previous release's
`linpeas-bundle.sbom.spdx.json` and runs `scripts/sbom-diff.sh` to
produce a deterministic, sorted markdown diff (added / removed /
version-changed packages). The diff is appended to the release body as
a collapsible `<details>` block.

Purpose: surface transitive-dependency churn that the Trivy CVE gate
cannot see — a new dependency with no known CVE is invisible to Trivy
but is itself worth review in a patch release.

Soft-fail semantics: if no previous release exists, or the previous
release has no `linpeas-bundle.sbom.spdx.json` asset (predates this
feature), the step logs and exits 0 without modifying the release body.

Idempotence: the append step is gated on `tag-exists == 'false'`, so a
`workflow_dispatch` rerun with `force-republish` will republish the
bundle and image artifacts but will NOT re-append the diff to an
existing release body. Avoids double-appending the same block.
