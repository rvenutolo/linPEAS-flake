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
- A release whose per-arch images have been evicted from the GHCR
    registry. See "Escape hatch" below.

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

## Escape hatch — registry image evicted

If `docker pull ghcr.io/rvenutolo/linpeas:<tag>-<arch>` fails because
the image has been evicted from GHCR (manual delete, retention
policy), the backfill workflow's image jobs will fail.

Recovery requires rebuilding the image at the historic commit:

1. Identify the commit that pinned `<tag>`:
    `git log --diff-filter=A --format='%H %s' -- linpeas-pin.json`
    then find the commit where `<tag>` first appeared in the JSON.
1. Locally check out that commit and run
    `nix build .#linpeas-image --print-build-logs`.
1. `docker load --input result` + retag + push to GHCR / Docker Hub
    under `${tag}-${arch}`.
1. Re-run `gh workflow run release-on-bump.yml --ref main -F backfill-tag=<tag>`.

Note that the rebuilt image must be byte-identical to the original
for cosign image-digest verification to match. The repository's
`reproducibility-check.yml` workflow asserts this property weekly;
verify it has been green for `<tag>` before relying on rebuild.

## Timestamps

The backfilled `.intoto.jsonl` bundles carry the BACKFILL workflow's
timestamp and SHA, not the original release's. This is correct: the
attestation predicate's `subject` is content hash, and consumers
verify content match, not emission time. Reviewers reading
`gh attestation list` may see a timestamp newer than the release
date — that is expected.
