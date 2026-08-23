#!/usr/bin/env bash
# scripts/compare-repro.sh
#
# @description Compare two reproducibility-build hash JSON files.
# Emits a markdown table to GITHUB_STEP_SUMMARY (or stdout if unset)
# and exits 0 on full match, 1 on any divergence, 2 on bad input. Bad
# input includes an absent, null, or malformed hash field: two builds
# that both measured nothing are not a match.

set -Eeuo pipefail
IFS=$'\n\t'

if [[ $# -ne 2 ]]; then
  printf 'usage: %s <build-a.json> <build-b.json>\n' "$0" >&2
  exit 2
fi

# Every field below is read with `jq`, and the shape probes report a
# failed read as a defect in the build-info file. An absent `jq` would
# therefore be announced as `not a JSON object` against a file that is a
# perfectly good JSON object. This script sources no libraries, so the
# guard is written out rather than taken from `require_tool`.
if ! command -v jq >/dev/null 2>&1; then
  printf 'ERROR: jq not found on PATH\n' >&2
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

# Expected shape per compared field. A present-but-worthless value — an
# absent key read back as the string `null`, or a measurement step that
# emitted an error token — must fail as bad input rather than compare
# equal against the same worthless value in the other build. Two builds
# that both measured nothing are not a reproducibility proof.
# @arg $1 field name
function expected_pattern() {
  case "$1" in
  linpeas_nar_hash) printf '%s' '^sha256-[A-Za-z0-9+/=]+$' ;;
  image_tar_sha256) printf '%s' '^[0-9a-f]{64}$' ;;
  image_manifest_digest) printf '%s' '^sha256:[0-9a-f]{64}$' ;;
  *)
    printf 'ERROR: no expected pattern for field: %s\n' "$1" >&2
    exit 2
    ;;
  esac
}

for f in "${BUILD_A}" "${BUILD_B}"; do
  if ! jq --exit-status 'type == "object"' "${f}" >/dev/null 2>&1; then
    printf 'ERROR: not a JSON object: %s\n' "${f}" >&2
    exit 2
  fi
  for field in "${FIELDS[@]}"; do
    if ! jq --exit-status --arg k "${field}" \
      '.[$k] | type == "string" and length > 0 and . != "null"' \
      "${f}" >/dev/null 2>&1; then
      printf 'ERROR: %s: field %s is absent, null, or empty\n' "${f}" "${field}" >&2
      exit 2
    fi
    value="$(jq --raw-output --arg k "${field}" '.[$k]' "${f}")"
    pattern="$(expected_pattern "${field}")"
    if [[ ! ${value} =~ ${pattern} ]]; then
      printf 'ERROR: %s: field %s has malformed value: %s\n' "${f}" "${field}" "${value}" >&2
      exit 2
    fi
  done
done
unset value pattern field

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
      a_val="$(jq --raw-output --arg k "${field}" '.[$k] // "(absent)"' "${BUILD_A}")"
      b_val="$(jq --raw-output --arg k "${field}" '.[$k] // "(absent)"' "${BUILD_B}")"
      printf "| \`%s\` | \`%s\` | \`%s\` |\n" "${field}" "${a_val}" "${b_val}"
    done
    printf '\n'
  }
  if [[ ${#mismatches[@]} -eq 0 ]]; then
    printf '**Result:** MATCH — builds are reproducible.\n'
  else
    # `${mismatches[*]}` would join on the first character of IFS, which
    # this script sets to a newline, splitting a multi-field verdict
    # across lines. Build the list with an explicit separator instead.
    # The terminating period closes the list, matching the MATCH verdict
    # and keeping a single-field verdict from reading as the opening of a
    # longer one.
    printf -v mismatch_list '%s ' "${mismatches[@]}"
    printf '**Result:** MISMATCH in: %s.\n' "${mismatch_list% }"
    if [[ -n ${GITHUB_SERVER_URL:-} && -n ${GITHUB_REPOSITORY:-} ]]; then
      printf '\nSee runbook: [%s](%s/%s/blob/main/%s)\n' \
        'docs/runbooks/reproducibility-check.md' \
        "${GITHUB_SERVER_URL}" "${GITHUB_REPOSITORY}" 'docs/runbooks/reproducibility-check.md'
    else
      printf '\nSee runbook: docs/runbooks/reproducibility-check.md\n'
    fi
  fi
} >>"${summary_out}"

if [[ ${#mismatches[@]} -gt 0 ]]; then
  exit 1
fi
exit 0
