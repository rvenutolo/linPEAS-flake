#!/usr/bin/env bash
# scripts/check-tag-protection.sh
#
# @description Lint: the live `release-tag-protection` ruleset
# matches the desired posture (tag target, active enforcement, ref
# include pattern, required rules).

# Lint: assert the live (or fixture-injected) tag-protection
# ruleset matches the desired posture:
#   - name "release-tag-protection"
#   - target "tag"
#   - enforcement "active"
#   - rules include "deletion" AND "update" AND "non_fast_forward"
#   - bypass_actors empty (no actor may bypass the deletion / update /
#     non_fast_forward rules)
#   - conditions.ref_name.include contains the canonical pin-version pattern
#     OR a strict superset (refs/tags/** is the documented fallback).
#
# Exits 0 on match, 1 on drift. Logs the specific drift to stderr.
# Exits 2 when the ruleset payload cannot be read as a ruleset at all: an
# unreadable source, an empty payload, one that is not JSON, one whose top
# level is not an object, or one carrying a wrong-typed field this lint
# reads. The diagnostic names the offending field and the payload source.
# A tooling fault must not borrow the drift code: that reads as a
# substantive ruleset change and sends a maintainer after a rule nobody
# removed. Absence is the exception — an absent `.rules` is an empty rule
# list and an absent `.bypass_actors` is "no actor may bypass", both of
# which are posture claims this lint judges (drift or pass), not faults.
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

# The payload this lint reads is either a fixture path or the ruleset API's
# response, and every read below assumes a shape neither source guarantees.
# Name the source in every could-not-run diagnostic: an operator who sees one
# needs to know which payload was wrong before anything else. The source is
# named by kind rather than by path, so a fixture's identity never reaches the
# output the census-parity gate compares.
if [[ -n ${RULESET_JSON_OVERRIDE:-} ]]; then
  payload_source='RULESET_JSON_OVERRIDE'
  if [[ ! -r ${RULESET_JSON_OVERRIDE} ]]; then
    printf 'release-tag-protection ruleset: payload from %s is not readable\n' "${payload_source}" >&2
    exit 2
  fi
else
  payload_source="/repos/${THIS_REPO}/rulesets"
fi
readonly payload_source

ruleset_json="$(fetch_ruleset)"

# One shape gate in front of every read, rather than a guard per read: a read
# added later is then total by construction instead of depending on its author
# remembering the convention. Absence is not uniformly a fault — GitHub returns
# `rules: []` for a ruleset carrying no rules, so an absent `.rules` stays an
# empty rule list (drift, exit 1), and an absent `.bypass_actors` stays "no
# actor may bypass". A repository ruleset always carries `conditions.ref_name`,
# so its absence means this is not a ruleset detail response at all.
# jq reads empty input as no input at all and exits 0, so emptiness is checked
# here rather than in the program below.
if [[ -z ${ruleset_json//[[:space:]]/} ]]; then
  printf 'release-tag-protection ruleset: empty payload from %s\n' "${payload_source}" >&2
  exit 2
fi
if ! shape_error="$(jq --raw-output '
  if type != "object" then "payload is \(type), want object"
  elif (.name | type) != "string" then ".name is \(.name | type), want string"
  elif (.target | type) != "string" then ".target is \(.target | type), want string"
  elif (.enforcement | type) != "string" then ".enforcement is \(.enforcement | type), want string"
  elif has("bypass_actors") and (.bypass_actors | type) != "array" then ".bypass_actors is \(.bypass_actors | type), want array"
  elif has("rules") and (.rules | type) != "array" then ".rules is \(.rules | type), want array"
  elif (.conditions | type) != "object" then ".conditions is \(.conditions | type), want object"
  elif (.conditions.ref_name | type) != "object" then ".conditions.ref_name is \(.conditions.ref_name | type), want object"
  elif (.conditions.ref_name.include | type) != "array" then ".conditions.ref_name.include is \(.conditions.ref_name.include | type), want array"
  else empty
  end' <<<"${ruleset_json}" 2>/dev/null)"; then
  printf 'release-tag-protection ruleset: payload from %s is not valid JSON\n' "${payload_source}" >&2
  exit 2
fi
if [[ -n ${shape_error} ]]; then
  printf 'release-tag-protection ruleset: unexpected payload shape from %s: %s\n' \
    "${payload_source}" "${shape_error}" >&2
  exit 2
fi

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

# --- bypass_actors must be empty --------------------------------------------

bypass_count="$(jq '.bypass_actors | length' <<<"${ruleset_json}")"
if ((bypass_count != 0)); then
  printf 'bypass_actors non-empty: got %d, want 0\n' "${bypass_count}" >&2
  jq '.bypass_actors' <<<"${ruleset_json}" >&2
  exit 1
fi

# Required rules: each must appear in .rules[].type.
#
# Capture jq's output (and exit status) into a variable rather than feeding
# mapfile from `< <(jq ...)`: a process substitution's exit status is
# invisible to `set -Eeuo pipefail`, so a jq error on an unexpected ruleset
# shape would yield an empty rule list and be reported as a missing rule —
# a tooling fault wearing the costume of substantive drift. `.rules // []`
# keeps an absent `.rules` an empty list (drift, exit 1); anything jq
# cannot iterate is a tooling fault (exit 2).
if ! rule_types="$(jq --raw-output '.rules // [] | .[].type' <<<"${ruleset_json}")"; then
  printf 'release-tag-protection ruleset: could not read .rules[].type (unexpected shape)\n' >&2
  exit 2
fi
actual_rules=()
# An empty capture must stay an empty array: `mapfile <<<""` would yield one
# empty-string element and misreport the have-list.
if [[ -n ${rule_types} ]]; then
  mapfile -t actual_rules <<<"${rule_types}"
fi
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
# Which of the two matched is the difference between a ruleset scoped to
# pin-version tags and one blanket-protecting every tag in the repo, so
# record it rather than collapsing both to a bare pass. The canonical
# pattern is reported when a ruleset carries both.
include_patterns="$(jq --raw-output '.conditions.ref_name.include[]' <<<"${ruleset_json}")"
if grep --quiet --fixed-strings -- "${EXPECTED_PATTERN_REGEX}" <<<"${include_patterns}"; then
  ref_match="pin-version pattern ${EXPECTED_PATTERN_REGEX}"
elif grep --quiet --fixed-strings -- "${FALLBACK_PATTERN_GLOB}" <<<"${include_patterns}"; then
  ref_match="fallback glob ${FALLBACK_PATTERN_GLOB}"
else
  printf 'ref_name.include does not contain expected pattern\n  have: %s\n  want one of: %s | %s\n' \
    "${include_patterns}" "${EXPECTED_PATTERN_REGEX}" "${FALLBACK_PATTERN_GLOB}" >&2
  exit 1
fi

# An empty capture must stay a zero count: `wc -l <<<""` counts the
# here-string's own trailing newline and would report one pattern where
# the ruleset has none.
include_count=0
if [[ -n ${include_patterns} ]]; then
  include_count="$(wc -l <<<"${include_patterns}")"
fi

# A bare pass tells an operator nothing about the posture that was
# accepted: a ruleset carrying extra rules, or one falling back to
# blanket tag protection, passes exactly like the canonical posture.
# State what was verified, and name which ref pattern carried the match.
printf 'tag-protection: %s verified — %d rule(s) in the ruleset, %d bypass actor(s), %d include pattern(s); ref match: %s\n' \
  "${EXPECTED_NAME}" "${#actual_rules[@]}" "${bypass_count}" \
  "${include_count}" "${ref_match}"

exit 0
