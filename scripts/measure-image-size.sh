#!/usr/bin/env bash
# scripts/measure-image-size.sh
#
# @description Measure two sizes of a built nix dockerTools image and
# emit them as JSON. Used by the image-smoke CI job to populate the
# size-advisory job summary and PR comment.
#
# Usage:
#   measure-image-size.sh <result-symlink> <flake-ref>
#
#   <result-symlink> — path to the `result` symlink from `nix build`,
#                      pointing at the compressed image tar.
#   <flake-ref>      — flake reference to the image attr (e.g. `.#linpeas-image`),
#                      passed to `nix path-info --closure-size` to compute
#                      the unpacked closure size.
#
# Output: single-line JSON `{"compressed_bytes": N, "closure_bytes": M}`
# on stdout. Both fields are positive integers (bytes).
#
# Exits 0 on success, non-zero on missing inputs or measurement failure.
# Diagnostic messages go to stderr.

set -Eeuo pipefail
IFS=$'\n\t'

if [[ $# -ne 2 ]]; then
  printf 'usage: %s <result-symlink> <flake-ref>\n' "$0" >&2
  exit 2
fi

readonly RESULT="$1"
readonly FLAKE_REF="$2"

if [[ ! -e ${RESULT} ]]; then
  printf 'ERROR: result path does not exist: %s\n' "${RESULT}" >&2
  exit 1
fi

# Resolve the symlink to the actual tar in the nix store, then stat it.
real_path="$(readlink -f -- "${RESULT}")"
if [[ ! -f ${real_path} ]]; then
  printf 'ERROR: result symlink does not resolve to a file: %s -> %s\n' \
    "${RESULT}" "${real_path}" >&2
  exit 1
fi

compressed="$(stat --format=%s -- "${real_path}")"

# nix path-info --closure-size returns the unpacked closure size in
# bytes for the derivation's output paths. The JSON shape changed
# between nix releases (array → object keyed by store path → object
# with a top-level "info" map), so use a recursive jq that pulls the
# first closureSize value regardless of wrapping. Capture stderr to a
# temp file so the script's own stderr stays clean for callers; only
# surface it if path-info fails.
tmpdir="$(mktemp -d)"
readonly TMPDIR_OWN="${tmpdir}"
trap 'rm -rf -- "${TMPDIR_OWN}"' EXIT

if ! nix path-info --closure-size --json -- "${FLAKE_REF}" \
  >"${TMPDIR_OWN}/info.json" 2>"${TMPDIR_OWN}/info.err"; then
  printf 'ERROR: nix path-info failed for %s:\n' "${FLAKE_REF}" >&2
  cat -- "${TMPDIR_OWN}/info.err" >&2
  exit 1
fi

closure="$(jq -r '[.. | objects | .closureSize? // empty] | .[0]' \
  <"${TMPDIR_OWN}/info.json")"

if ! [[ ${closure} =~ ^[0-9]+$ ]]; then
  printf 'ERROR: nix path-info did not return a numeric closure size: %s\n' \
    "${closure}" >&2
  exit 1
fi

printf '{"compressed_bytes": %s, "closure_bytes": %s}\n' \
  "${compressed}" "${closure}"
