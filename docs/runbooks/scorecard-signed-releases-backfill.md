# Scorecard Signed-Releases backfill runbook

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

- A current-tag release missing images, the manifest, or the pin
    `.sigstore` bundle — use `force-republish` instead. (A current
    release missing `linpeas-pin.json.intoto.jsonl` IS this runbook's
    case — see the trigger conditions above: `force-republish` re-runs
    neither the provenance attestation nor the sidecar upload, both
    gated on the release not existing OR `backfill-tag`, so use
    `backfill-tag=<current tag>`.) - A release with a PARTIAL per-arch
    image set (some but not all six of the
    `{ghcr.io,docker.io}:<tag>-{amd64,arm64}` tags and the
    `{ghcr.io,docker.io}:<tag>` indexes present). The preflight fails
    loudly on this half-published state — see "Partial image set" below.

An IMAGE-LESS release (all six absent) is fully supported: backfill
writes the pin sidecars, the image jobs skip, and the run finishes
green. No image rebuild is required.

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
    digests — read out of each registry's `:<tag>` index, never from
    the mutable `<tag>-<arch>` tags — regenerates each
    `linpeas-image-<arch>.cdx.json` SBOM, signs it, attests its bytes,
    and uploads all three asset shapes.
- Rebuilds the multi-arch index from the existing per-arch digests
    (byte-identical to the original publish) and re-signs it
    (idempotent at registry). `:latest` is left alone unless the
    backfilled tag is the newest release, so a historic backfill never
    repoints it.
- Skips the changelog job (release notes are NOT rewritten).

Run sequentially per tag (workflow concurrency group
`release-on-bump-main` serializes anyway).

## Verification

After backfill:

```bash
gh release view <tag> --json assets --jq '.assets[].name' | sort
```

Expect every primary artifact the release actually carries —
`linpeas-pin.json` always, plus `linpeas-image-<arch>.cdx.json` on an
image-backed release — to have BOTH a `.sigstore` and a
`.intoto.jsonl` sibling. On an image-less backfill the image jobs
skip, so only the pin artifact and its two sidecars are expected.

Then trigger the scorecard watchdog:

```bash
gh workflow run scorecard-drift-check.yml
```

Expect:

- No `Signed-Releases: <N>` offender line — the threshold script prints only
    checks scoring below 10.
- Workflow run green.
- Issue auto-closed by `notify-workflow-result` deduper.

## Partial image set

The `preflight` job probes six registry objects — the four per-arch
tags (`{ghcr.io,docker.io}/rvenutolo/linpeas:<tag>-{amd64,arm64}`) and
the multi-arch index on each registry
(`{ghcr.io,docker.io}/rvenutolo/linpeas:<tag>`) — and classifies the
release:

- **all six present** → the per-arch digests are read from each
    registry's index, the images are pulled at those digests, image
    SBOM sidecars are regenerated, and the multi-arch index is
    rebuilt.
- **all six absent** → image-less; the image/manifest jobs skip and
    only the pin sidecars are backfilled. The run is green.
- **partial** (1–5 present) → `preflight` fails. This is a
    half-published state no automatic path can safely repair.

The index is a required signal because it is the only in-registry
record of which per-arch digests the release shipped. A release whose
arch tags all survive but whose index was evicted leaves backfill
nothing to source by except a mutable tag, and blessing a repointed
tag with fresh attestations and a fresh signature is the outcome
pulling by digest exists to prevent. An index that records anything
other than exactly one `linux/<arch>` manifest per arch also fails the
preflight rather than being guessed at.

To resolve a partial set, restore the missing per-arch images by
rebuilding at the historic commit, then re-run the backfill:

1. Identify the commit that pinned `<tag>`:
    `git log -S'<tag>' --reverse --format='%H %s' -- linpeas-pin.json | head -1`.
    `-S` selects the commits where the tag's occurrence count changed —
    the one that introduced it and the one that later replaced it — so
    `--reverse` plus `head -1` takes the introducing commit.
1. Locally check out that commit and run
    `nix build .#linpeas-image --print-build-logs`.
1. `docker load --input result` + retag + push to GHCR / Docker Hub
    under `${tag}-${arch}` for the missing arch(es)/registry(ies). If
    the `:<tag>` index is the missing object, rebuild it with
    `docker buildx imagetools create --tag <reg>/rvenutolo/linpeas:<tag>`
    over both per-arch digest refs.
1. Re-run `gh workflow run release-on-bump.yml --ref main -F backfill-tag=<tag>`.

The rebuilt image must be byte-identical to the original for cosign
image-digest verification to match. The weekly
`reproducibility-check.yml` run only covers the *current* pin built
from the default branch, so it says nothing about a historic `<tag>` —
verify the rebuild directly by comparing the rebuilt per-arch digests
against the digests recorded in the release's `:<tag>` index before
pushing. If you cite the weekly check's signal at all, check for open
`reproducibility`-labelled issues rather than workflow-level green:
`continue-on-error` on its compare job keeps runs green even on
mismatch during burn-in.

Restoring images to an image-less release (making all six present — the
four per-arch tags **and** both `:<tag>` indexes) is optional and uses
the same rebuild-and-push steps for every arch. Pushing only the four
per-arch tags leaves the release at four-of-six, a partial set the
preflight refuses to guess at and hard-fails on.

## Timestamps

The backfilled `.intoto.jsonl` bundles carry the BACKFILL workflow's
timestamp and SHA, not the original release's. This is correct: the
attestation predicate's `subject` is content hash, and consumers verify
content match, not emission time. Reviewers reading `gh attestation download <artifact> --repo rvenutolo/linPEAS-flake` may see a timestamp
newer than the release date — that is expected.
