#!/usr/bin/env bash
# scripts/classify-backfill-image-mode.sh
#
# @description Classify whether a release-on-bump `backfill-tag` run
# should exercise the per-arch image pipeline. Given the presence
# (`present`/`absent`) of six registry objects in the order
# amd64@ghcr amd64@hub arm64@ghcr arm64@hub index@ghcr index@hub,
# print `full` when all six exist, `none` when all six are absent, and
# fail on any partial mix. Pure and side-effect free so the decision is
# unit-testable without contacting a registry.

# `full` -> the release has a complete per-arch image set AND the
# `:<tag>` multi-arch index that records which per-arch digests it
# shipped; backfill reads those digests out of the index, pulls the
# images by digest, regenerates the image SBOM sidecars, and rebuilds
# the index. The index is a required signal, not a bonus one: it is the
# only in-registry record of the historic digests, and without it the
# run has nothing to pull by except a mutable arch tag. `none` -> the
# release never had images (or every object was evicted); backfill
# writes only the pin sidecars while the image jobs skip, so the run
# finishes green. A partial mix (some but not all six present) is a
# half-published anomaly no automatic path can safely repair, so it is
# a hard error. See docs/runbooks/scorecard-signed-releases-backfill.md.
#
# Exit codes:
#   0  classified: `full` or `none` on stdout
#   1  a partial mix — some but not all six objects exist, the
#      half-published state this refuses to guess at
#   2  it could not classify: the argument count is not six, or an
#      argument is neither `present` nor `absent`

set -Eeuo pipefail
IFS=$'\n\t'

readonly WANT_ARGS=6

if [[ $# -ne ${WANT_ARGS} ]]; then
  printf 'usage: %s <amd64@ghcr> <amd64@hub> <arm64@ghcr> <arm64@hub> <index@ghcr> <index@hub>\n' \
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
"${WANT_ARGS}") printf 'full\n' ;;
0) printf 'none\n' ;;
*)
  printf 'partial image presence: %d of %d per-arch tags and indexes exist; refusing to guess (see docs/runbooks/scorecard-signed-releases-backfill.md)\n' \
    "${present_count}" "${WANT_ARGS}" >&2
  exit 1
  ;;
esac
