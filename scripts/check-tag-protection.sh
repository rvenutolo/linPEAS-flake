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
# Honors RELEASE_TAG_RULESET_JSON_OVERRIDE for the test harness — points at
# a fixture instead of hitting the live API. The variable is named for the
# ruleset this lint reads, because a sibling lint reads a different ruleset
# through the same API route and one variable shared between them would feed
# a single fixture to both whenever one process runs the pair.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/payload.sh
source "${_lib_dir}/lib/payload.sh"

# The ruleset is read from the API, so an absent `gh` means the check
# read nothing. Unguarded it exits 1, which reads as a drifted ruleset.
require_tool gh

readonly EXPECTED_NAME='release-tag-protection'
readonly EXPECTED_TARGET='tag'
readonly EXPECTED_ENFORCEMENT='active'
readonly REQUIRED_RULES=('deletion' 'update' 'non_fast_forward')
readonly EXPECTED_PATTERN_REGEX='refs/tags/[0-9]{8}-[0-9a-f]{7,40}'
readonly FALLBACK_PATTERN_GLOB='refs/tags/**'
readonly THIS_REPO='rvenutolo/linPEAS-flake'

# @description Fetch the live ruleset JSON from the rulesets API.
# Both calls are status-checked. `gh` present but failing — an API
# error, an expired token, no network — exits 1, and an unchecked
# assignment hands that 1 to the caller as this check's own verdict,
# which reads as a drifted ruleset rather than as a fetch that never
# happened. An empty ruleset list is a different answer: the API
# answered, and no ruleset by this name is a finding about the repo.
function fetch_ruleset() {
  # Live mode: list rulesets, filter by name, fetch detail.
  local id
  if ! id="$(gh api --header 'X-GitHub-Api-Version: 2022-11-28' \
    "/repos/${THIS_REPO}/rulesets" \
    --jq ".[] | select(.name==\"${EXPECTED_NAME}\") | .id")"; then
    log_err "cannot list rulesets for ${THIS_REPO}: GitHub API call failed"
    exit 2
  fi
  if [[ -z ${id} ]]; then
    printf 'no ruleset named %q on %s\n' "${EXPECTED_NAME}" "${THIS_REPO}" >&2
    exit 1
  fi
  local body
  if ! body="$(gh api --header 'X-GitHub-Api-Version: 2022-11-28' \
    "/repos/${THIS_REPO}/rulesets/${id}")"; then
    log_err "cannot fetch ruleset ${id} for ${THIS_REPO}: GitHub API call failed"
    exit 2
  fi
  printf '%s' "${body}"
}

# The payload this lint reads is either a fixture path or the ruleset API's
# response, and every read below assumes a shape neither source guarantees.
payload_source_into payload_source RELEASE_TAG_RULESET_JSON_OVERRIDE \
  "/repos/${THIS_REPO}/rulesets/{id}"
readonly payload_source

# read_json_payload_into fills a nameref, so it must run in this shell —
# never inside `$(...)`, where its `exit 2` would be trapped in a
# subshell and this script would carry on with an empty ruleset_json.
# That is why the override branch is hoisted out of fetch_ruleset rather
# than living inside it.
if [[ -n ${RELEASE_TAG_RULESET_JSON_OVERRIDE:-} ]]; then
  read_json_payload_into ruleset_json "${RELEASE_TAG_RULESET_JSON_OVERRIDE}" \
    "${payload_source}" "${EXPECTED_NAME} ruleset"
else
  ruleset_json="$(fetch_ruleset)"
fi

# One shape gate in front of every read, rather than a guard per read: a read
# added later is then total by construction instead of depending on its author
# remembering the convention. Absence is not uniformly a fault — GitHub returns
# `rules: []` for a ruleset carrying no rules, so an absent `.rules` stays an
# empty rule list (drift, exit 1), and an absent `.bypass_actors` stays "no
# actor may bypass". A repository ruleset always carries `conditions.ref_name`,
# so its absence means this is not a ruleset detail response at all.
#
# The subject is passed because the source kind alone does not identify this
# payload: a sibling lint reads a different ruleset through the same API
# route.
require_json_payload "${payload_source}" "${ruleset_json}" '
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
  end' "${EXPECTED_NAME} ruleset"

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
  printf '%s ruleset: could not read .rules[].type (unexpected shape)\n' "${EXPECTED_NAME}" >&2
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
