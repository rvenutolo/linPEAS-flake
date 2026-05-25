#!/usr/bin/env bash
# scripts/compare-repro.sh
#
# @description Compare two reproducibility-build hash JSON files.
# Emits a markdown table to GITHUB_STEP_SUMMARY (or stdout if unset)
# and exits 0 on full match, 1 on any divergence, 2 on bad input.

set -Eeuo pipefail
IFS=$'\n\t'

if [[ $# -ne 2 ]]; then
  printf 'usage: %s <build-a.json> <build-b.json>\n' "$0" >&2
  exit 2
fi

readonly BUILD_A="$1"
readonly BUILD_B="$2"

for f in "${BUILD_A}" "${BUILD_B}"; do
  if [[ ! -f ${f} ]]; then
    printf 'ERROR: input file does not exist: %s\n' "${f}" >&2
    exit 2
  fi
done

readonly FIELDS=(
  linpeas_nar_hash
  image_tar_sha256
  image_manifest_digest
)

summary_out="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

mismatches=()
{
  printf '## Reproducibility Check\n\n'
  printf '| Field | Build A | Build B | Status |\n'
  printf '|---|---|---|---|\n'
  for field in "${FIELDS[@]}"; do
    a_val="$(jq -r --arg k "${field}" '.[$k]' "${BUILD_A}")"
    b_val="$(jq -r --arg k "${field}" '.[$k]' "${BUILD_B}")"
    if [[ ${a_val} == "${b_val}" ]]; then
      status='match'
    else
      status='**MISMATCH**'
      mismatches+=("${field}")
    fi
    printf "| \`%s\` | \`%s\` | \`%s\` | %s |\n" \
      "${field}" "${a_val}" "${b_val}" "${status}"
  done
  printf '\n'
  {
    printf '### Build paths (informational)\n\n'
    printf '| Field | Build A | Build B |\n'
    printf '|---|---|---|\n'
    for field in linpeas_store_path image_store_path; do
      a_val="$(jq -r --arg k "${field}" '.[$k]' "${BUILD_A}")"
      b_val="$(jq -r --arg k "${field}" '.[$k]' "${BUILD_B}")"
      printf "| \`%s\` | \`%s\` | \`%s\` |\n" "${field}" "${a_val}" "${b_val}"
    done
    printf '\n'
  }
  if [[ ${#mismatches[@]} -eq 0 ]]; then
    printf '**Result:** MATCH — builds are reproducible.\n'
  else
    printf '**Result:** MISMATCH in: %s\n' "${mismatches[*]}"
    printf '\nSee runbook: [docs/runbooks/reproducibility-check.md](../blob/main/docs/runbooks/reproducibility-check.md)\n'
  fi
} >>"${summary_out}"

if [[ ${#mismatches[@]} -gt 0 ]]; then
  exit 1
fi
exit 0
