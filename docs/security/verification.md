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
