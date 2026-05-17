#!/usr/bin/env bash
# scripts/check-tag-protection.sh
#
# P2.3 / GAP-9 lint: assert the live (or fixture-injected) tag-protection
# ruleset matches the desired posture:
#   - name "release-tag-protection"
#   - target "tag"
#   - enforcement "active"
#   - rules include "deletion" AND "update" AND "non_fast_forward"
#   - conditions.ref_name.include contains the canonical pin-version pattern
#     OR a strict superset (refs/tags/** is the documented fallback).
#
# Exits 0 on match, 1 on drift. Logs the specific drift to stderr.
#
# Honors RULESET_JSON_OVERRIDE for the test harness — points at a fixture
# instead of hitting the live API.

set -Eeuo pipefail
IFS=$'\n\t'

readonly EXPECTED_NAME='release-tag-protection'
readonly EXPECTED_TARGET='tag'
readonly EXPECTED_ENFORCEMENT='active'
readonly REQUIRED_RULES=('deletion' 'update' 'non_fast_forward')
readonly EXPECTED_PATTERN_REGEX='refs/tags/[0-9]{8}-[0-9a-f]{7,40}'
readonly FALLBACK_PATTERN_GLOB='refs/tags/**'
readonly THIS_REPO='rvenutolo/linPEAS-flake'

# @description Fetch the ruleset JSON either from override fixture or
# from the live gh api.
function fetch_ruleset() {
  local -r override="${RULESET_JSON_OVERRIDE:-}"
  if [[ -n ${override} ]]; then
    cat -- "${override}"
    return
  fi
  # Live mode: list rulesets, filter by name, fetch detail.
  local id
  id="$(gh api --header 'X-GitHub-Api-Version: 2022-11-28' \
    "/repos/${THIS_REPO}/rulesets" \
    --jq ".[] | select(.name==\"${EXPECTED_NAME}\") | .id")"
  if [[ -z ${id} ]]; then
    printf 'no ruleset named %q on %s\n' "${EXPECTED_NAME}" "${THIS_REPO}" >&2
    exit 1
  fi
  gh api --header 'X-GitHub-Api-Version: 2022-11-28' \
    "/repos/${THIS_REPO}/rulesets/${id}"
}

ruleset_json="$(fetch_ruleset)"

name="$(jq --raw-output .name <<<"${ruleset_json}")"
target="$(jq --raw-output .target <<<"${ruleset_json}")"
enforcement="$(jq --raw-output .enforcement <<<"${ruleset_json}")"

if [[ ${name} != "${EXPECTED_NAME}" ]]; then
  printf 'name drift: got %q, want %q\n' "${name}" "${EXPECTED_NAME}" >&2
  exit 1
fi
if [[ ${target} != "${EXPECTED_TARGET}" ]]; then
  printf 'target drift: got %q, want %q\n' "${target}" "${EXPECTED_TARGET}" >&2
  exit 1
fi
if [[ ${enforcement} != "${EXPECTED_ENFORCEMENT}" ]]; then
  printf 'enforcement drift: got %s, want %s\n' "${enforcement}" "${EXPECTED_ENFORCEMENT}" >&2
  exit 1
fi

# Required rules: each must appear in .rules[].type.
mapfile -t actual_rules < <(jq --raw-output '.rules[].type' <<<"${ruleset_json}")
for required in "${REQUIRED_RULES[@]}"; do
  found=0
  for actual in "${actual_rules[@]}"; do
    if [[ ${actual} == "${required}" ]]; then
      found=1
      break
    fi
  done
  if ((!found)); then
    printf 'missing rule: %s (have: %s)\n' "${required}" "${actual_rules[*]}" >&2
    exit 1
  fi
done

# Pattern: accept the canonical regex OR the documented fallback glob.
include_patterns="$(jq --raw-output '.conditions.ref_name.include[]' <<<"${ruleset_json}")"
if ! grep --quiet --fixed-strings -- "${EXPECTED_PATTERN_REGEX}" <<<"${include_patterns}" &&
  ! grep --quiet --fixed-strings -- "${FALLBACK_PATTERN_GLOB}" <<<"${include_patterns}"; then
  printf 'ref_name.include does not contain expected pattern\n  have: %s\n  want one of: %s | %s\n' \
    "${include_patterns}" "${EXPECTED_PATTERN_REGEX}" "${FALLBACK_PATTERN_GLOB}" >&2
  exit 1
fi

exit 0
