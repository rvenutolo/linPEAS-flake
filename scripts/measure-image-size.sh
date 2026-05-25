#!/usr/bin/env bash
# scripts/measure-image-size.sh
#
# @description Measure two sizes of a built dockerTools image tar.gz
# and emit them as JSON. Used by the image-smoke CI job to populate
# the size-advisory job summary and PR comment.
#
# Usage:
#   measure-image-size.sh <result-symlink>
#
#   <result-symlink> — path to the `result` symlink from `nix build`,
#                      pointing at the compressed image tar.
#
# Output: single-line JSON `{"compressed_bytes": N, "uncompressed_bytes": M}`
# on stdout. Both fields are positive integers (bytes). "Compressed" is
# the on-wire/at-rest tar.gz size; "uncompressed" is the extracted
# tar size — what the image takes on disk when pulled.
#
# Exits 0 on success, non-zero on missing inputs or measurement failure.
# Diagnostic messages go to stderr.

set -Eeuo pipefail
IFS=$'\n\t'

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <result-symlink>\n' "$0" >&2
  exit 2
fi

readonly RESULT="$1"

if [[ ! -e ${RESULT} ]]; then
  printf 'ERROR: result path does not exist: %s\n' "${RESULT}" >&2
  exit 1
fi

real_path="$(readlink -f -- "${RESULT}")"
if [[ ! -f ${real_path} ]]; then
  printf 'ERROR: result symlink does not resolve to a file: %s -> %s\n' \
    "${RESULT}" "${real_path}" >&2
  exit 1
fi

compressed="$(stat --format=%s -- "${real_path}")"

# `gunzip --list` prints a 2-line table: header + data. The data row's
# second column is the uncompressed size in bytes. We use --list rather
# than decompressing to a temp file because we only need the size.
# With --quiet the header is suppressed, so the data row is NR==1.
gz_list="$(gunzip --list --quiet -- "${real_path}")"
uncompressed="$(awk 'NR==1 {print $2}' <<<"${gz_list}")"

if ! [[ ${uncompressed} =~ ^[0-9]+$ ]]; then
  printf 'ERROR: gunzip --list did not return a numeric uncompressed size: %s\n' \
    "${uncompressed}" >&2
  exit 1
fi

printf '{"compressed_bytes": %s, "uncompressed_bytes": %s}\n' \
  "${compressed}" "${uncompressed}"
