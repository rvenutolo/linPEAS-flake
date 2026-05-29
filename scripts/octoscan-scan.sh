#!/usr/bin/env bash
# scripts/octoscan-scan.sh
#
# @description Run synacktiv/octoscan against `.github/workflows`
# via the pinned ghcr container image. Single source of truth for
# the image digest, the version label tracked by Renovate, and the
# exit-code mapping shared by the CI workflow and the pre-commit
# hook.
#
# Usage:
#   scripts/octoscan-scan.sh                 # text output to stdout
#   scripts/octoscan-scan.sh --sarif <path>  # SARIF output to <path>
#
# Exit codes:
#   0 — scan clean
#   1 — findings present, OR real error (docker missing,
#       image pull failure, scanner internal error). The caller
#       must distinguish via the `has-finding` line printed to
#       stdout (`has-finding=true|false`) — same contract the CI
#       workflow already exposes via `$GITHUB_OUTPUT`.
#
# Renovate manages OCTOSCAN_DIGEST + OCTOSCAN_VERSION in lockstep
# (renovate.json customManager scoped to this file).

set -Eeuo pipefail
IFS=$'\n\t'

OCTOSCAN_DIGEST="sha256:3368f42651f9ca0d7a7cd08de3b734476046d17ffa0b2b0c6c55acef556300db"
OCTOSCAN_VERSION="v0.1.7"
# shellcheck disable=SC2034 # Renovate reads OCTOSCAN_VERSION to track the version label in lockstep with OCTOSCAN_DIGEST.
readonly OCTOSCAN_DIGEST OCTOSCAN_VERSION

sarif_out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --sarif)
    [[ $# -ge 2 ]] || {
      printf 'error: --sarif requires a path argument\n' >&2
      exit 1
    }
    sarif_out="$2"
    shift 2
    ;;
  --help | -h)
    sed -n '2,/^$/p' "$0" | sed 's|^# \{0,1\}||'
    exit 0
    ;;
  *)
    printf 'error: unknown argument: %s\n' "$1" >&2
    exit 1
    ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  printf 'octoscan pre-commit hook requires docker.\n' >&2
  printf 'Install docker, or skip the hook for one commit with:\n' >&2
  printf '  SKIP=octoscan git commit ...\n' >&2
  printf 'has-finding=false\n'
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")"

rc=0
if [[ -n ${sarif_out} ]]; then
  docker run --rm \
    -v "${repo_root}:/src:ro" \
    "ghcr.io/synacktiv/octoscan@${OCTOSCAN_DIGEST}" \
    scan /src/.github/workflows \
    --format sarif \
    >"${sarif_out}" || rc=$?
else
  docker run --rm \
    -v "${repo_root}:/src:ro" \
    "ghcr.io/synacktiv/octoscan@${OCTOSCAN_DIGEST}" \
    scan /src/.github/workflows || rc=$?
fi

case "${rc}" in
0)
  printf 'has-finding=false\n'
  exit 0
  ;;
2)
  printf 'has-finding=true\n'
  exit 1
  ;;
*)
  # Truncated/partial SARIF is worse than missing SARIF; drop it
  # so downstream consumers (CI upload-sarif) skip cleanly instead
  # of uploading garbage.
  [[ -n ${sarif_out} ]] && rm -f -- "${sarif_out}"
  printf 'has-finding=false\n'
  exit 1
  ;;
esac
