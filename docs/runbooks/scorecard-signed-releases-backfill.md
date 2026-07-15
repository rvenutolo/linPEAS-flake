# Scorecard Signed-Releases backfill

Recovery procedure when the weekly `scorecard-drift-check` watchdog
reports `Signed-Releases` below 10 because a historic release lacks
the required `.sigstore` and/or `.intoto.jsonl` sidecar assets.

## When to use

Trigger conditions:

- `scripts/check-scorecard-threshold.sh` prints
    `Signed-Releases: <N>` with `N < 10` on a scheduled
    `scorecard-drift-check.yml` run.
- `gh release view <tag> --json assets` on one of the last five
    releases shows missing `.sigstore` or `.intoto.jsonl` sibling
    assets next to the published artifacts.

Do NOT use for:

- A current-tag release missing assets due to a partial publish —
    use `force-republish` instead.
- A release with a PARTIAL per-arch image set (some but not all four
    `{ghcr.io,docker.io}:<tag>-{amd64,arm64}` tags present). The
    preflight fails loudly on this half-published state — see
    "Partial image set" below.

An IMAGE-LESS release (all four per-arch tags absent) is fully
supported: backfill writes the pin sidecars, the image jobs skip, and
the run finishes green. No image rebuild is required.

## Procedure

For each affected release tag:

```bash
gh workflow run release-on-bump.yml --ref main -F backfill-tag=<tag>
```

The workflow:

- Downloads the existing `linpeas-pin.json` asset, re-attests its
    bytes, and uploads `linpeas-pin.json.intoto.jsonl` +
    `linpeas-pin.json.sigstore`.
- Pulls the per-arch images from GHCR + Docker Hub at the historic
    digests, regenerates each `linpeas-image-<arch>.cdx.json` SBOM,
    signs it, attests its bytes, and uploads all three asset shapes.
- Rebuilds the multi-arch index from the existing per-arch digests
    (byte-identical to the original publish) and re-signs it
    (idempotent at registry).
- Skips the changelog job (release notes are NOT rewritten).

Run sequentially per tag (workflow concurrency group
`release-on-bump-main` serializes anyway).

## Verification

After backfill:

```bash
gh release view <tag> --json assets --jq '.assets[].name' | sort
```

Expect every release-asset name to have BOTH a `.sigstore` and a
`.intoto.jsonl` sibling.

Then trigger the scorecard watchdog:

```bash
gh workflow run scorecard-drift-check.yml
```

Expect:

- `Signed-Releases: 10`.
- Workflow run green.
- Issue auto-closed by `notify-workflow-result` deduper.

## Partial image set

The `preflight` job probes the four per-arch tags
(`{ghcr.io,docker.io}/rvenutolo/linpeas:<tag>-{amd64,arm64}`) and
classifies the release:

- **all four present** → images are pulled, image SBOM sidecars
    regenerated, the multi-arch index rebuilt.
- **all four absent** → image-less; the image/manifest jobs skip and
    only the pin sidecars are backfilled. The run is green.
- **partial** (1–3 present) → `preflight` fails. This is a
    half-published state no automatic path can safely repair.

To resolve a partial set, restore the missing per-arch images by
rebuilding at the historic commit, then re-run the backfill:

1. Identify the commit that pinned `<tag>`:
    `git log --diff-filter=A --format='%H %s' -- linpeas-pin.json`
    then find the commit where `<tag>` first appeared in the JSON.
1. Locally check out that commit and run
    `nix build .#linpeas-image --print-build-logs`.
1. `docker load --input result` + retag + push to GHCR / Docker Hub
    under `${tag}-${arch}` for the missing arch(es)/registry(ies).
1. Re-run `gh workflow run release-on-bump.yml --ref main -F backfill-tag=<tag>`.

The rebuilt image must be byte-identical to the original for cosign
image-digest verification to match. `reproducibility-check.yml`
asserts this weekly; confirm it has been green for `<tag>` before
relying on a rebuild.

Restoring images to an image-less release (making all four present) is
optional and uses the same rebuild-and-push steps for every arch.

## Timestamps

The backfilled `.intoto.jsonl` bundles carry the BACKFILL workflow's
timestamp and SHA, not the original release's. This is correct: the
attestation predicate's `subject` is content hash, and consumers
verify content match, not emission time. Reviewers reading
`gh attestation list` may see a timestamp newer than the release
date — that is expected.
