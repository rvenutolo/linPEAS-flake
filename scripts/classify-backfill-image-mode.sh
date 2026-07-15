#!/usr/bin/env bash
# scripts/classify-backfill-image-mode.sh
#
# @description Classify whether a release-on-bump `backfill-tag` run
# should exercise the per-arch image pipeline. Given the presence
# (`present`/`absent`) of the four per-arch container tags in the
# order amd64@ghcr amd64@hub arm64@ghcr arm64@hub, print `full` when
# all four exist, `none` when all four are absent, and fail on any
# partial mix. Pure and side-effect free so the decision is
# unit-testable without contacting a registry.

# `full` -> the release has a complete per-arch image set; backfill
# pulls the historic digests, regenerates the image SBOM sidecars, and
# rebuilds the multi-arch index. `none` -> the release never had
# images (or all four were evicted); backfill writes only the pin
# sidecars while the image jobs skip, so the run finishes green. A
# partial mix (some but not all four tags present) is a half-published
# anomaly no automatic path can safely repair, so it is a hard error.
# See docs/runbooks/scorecard-signed-releases-backfill.md.

set -Eeuo pipefail
IFS=$'\n\t'

if [[ $# -ne 4 ]]; then
  printf 'usage: %s <amd64@ghcr> <amd64@hub> <arm64@ghcr> <arm64@hub>\n' \
    "${0##*/}" >&2
  printf 'each argument must be "present" or "absent"\n' >&2
  exit 2
fi

present_count=0
for arg in "$@"; do
  case "${arg}" in
  present) present_count=$((present_count + 1)) ;;
  absent) ;;
  *)
    printf 'invalid presence token %q (want "present" or "absent")\n' \
      "${arg}" >&2
    exit 2
    ;;
  esac
done

case "${present_count}" in
4) printf 'full\n' ;;
0) printf 'none\n' ;;
*)
  printf 'partial image presence: %d of 4 per-arch tags exist; refusing to guess (see docs/runbooks/scorecard-signed-releases-backfill.md)\n' \
    "${present_count}" >&2
  exit 1
  ;;
esac
