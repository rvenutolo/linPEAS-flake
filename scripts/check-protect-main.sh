#!/usr/bin/env bash
# scripts/check-protect-main.sh
#
# Lint: assert the live (or fixture-injected) `protect-main` branch
# ruleset matches the desired posture AND the in-tree mirror at
# `.github/rulesets/protect-main.json`.
#
# Mirrors the pattern in scripts/check-tag-protection.sh, closing the
# asymmetry where the tag-protection ruleset had a CI drift check but
# the branch-protection ruleset relied on review discipline alone.
#
# Asserted invariants:
#   - ruleset name `protect-main`
#   - target `branch`, enforcement `active`
#   - conditions.ref_name.include == ["~DEFAULT_BRANCH"]
#   - bypass_actors == []
#   - rules include `deletion`, `non_fast_forward`, `required_signatures`
#   - pull_request rule allowed_merge_methods == ["merge"]
#   - required-status-checks set matches the in-tree mirror (semantic
#     diff: sorted by context, integration_id ignored)
#
# Exits 0 on match, 1 on drift. Logs the specific drift to stderr.
#
# Env overrides (test-only):
#   RULESET_JSON_OVERRIDE — path to a fixture JSON for the live ruleset
#   MIRROR_JSON_OVERRIDE  — path to a fixture JSON for the in-tree mirror

set -Eeuo pipefail
IFS=$'\n\t'

readonly EXPECTED_NAME='protect-main'
readonly EXPECTED_TARGET='branch'
readonly EXPECTED_ENFORCEMENT='active'
readonly REQUIRED_RULES=('deletion' 'non_fast_forward' 'required_signatures')
readonly EXPECTED_REF_INCLUDE='~DEFAULT_BRANCH'
readonly EXPECTED_MERGE_METHODS='["merge"]'
readonly THIS_REPO='rvenutolo/linPEAS-flake'

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf '.')"
readonly REPO_ROOT
readonly MIRROR_FILE="${MIRROR_JSON_OVERRIDE:-${REPO_ROOT}/.github/rulesets/protect-main.json}"

# @description Fetch the live ruleset JSON or read the override fixture.
function fetch_ruleset() {
  local -r override="${RULESET_JSON_OVERRIDE:-}"
  if [[ -n ${override} ]]; then
    cat -- "${override}"
    return
  fi
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

if [[ ! -f ${MIRROR_FILE} ]]; then
  printf 'mirror file not found: %s\n' "${MIRROR_FILE}" >&2
  exit 1
fi

ruleset_json="$(fetch_ruleset)"
mirror_json="$(cat -- "${MIRROR_FILE}")"

# --- Top-level shape ---------------------------------------------------------

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
  printf 'enforcement drift: got %q, want %q\n' \
    "${enforcement}" "${EXPECTED_ENFORCEMENT}" >&2
  exit 1
fi

# --- bypass_actors must be empty --------------------------------------------

bypass_count="$(jq '.bypass_actors | length' <<<"${ruleset_json}")"
if ((bypass_count != 0)); then
  printf 'bypass_actors non-empty: got %d, want 0\n' "${bypass_count}" >&2
  jq '.bypass_actors' <<<"${ruleset_json}" >&2
  exit 1
fi

# --- conditions.ref_name.include == ["~DEFAULT_BRANCH"] ---------------------

include_count="$(jq '.conditions.ref_name.include | length' <<<"${ruleset_json}")"
include_first="$(jq --raw-output '.conditions.ref_name.include[0] // empty' \
  <<<"${ruleset_json}")"
if ((include_count != 1)) || [[ ${include_first} != "${EXPECTED_REF_INCLUDE}" ]]; then
  printf 'conditions.ref_name.include drift: got %s, want [%s]\n' \
    "$(jq -c '.conditions.ref_name.include' <<<"${ruleset_json}")" \
    "${EXPECTED_REF_INCLUDE}" >&2
  exit 1
fi

# --- required rules present -------------------------------------------------

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

# --- pull_request rule: allowed_merge_methods == ["merge"] ------------------

merge_methods="$(jq --compact-output \
  '.rules[] | select(.type=="pull_request") | .parameters.allowed_merge_methods' \
  <<<"${ruleset_json}")"
if [[ ${merge_methods} != "${EXPECTED_MERGE_METHODS}" ]]; then
  printf 'allowed_merge_methods drift: got %s, want %s\n' \
    "${merge_methods}" "${EXPECTED_MERGE_METHODS}" >&2
  exit 1
fi

# --- required-status-checks parity with in-tree mirror ----------------------
# Semantic diff: sort by context, drop integration_id and any other inert
# defaults; compare the resulting context list.

live_contexts="$(jq --compact-output \
  '.rules[] | select(.type=="required_status_checks") |
   .parameters.required_status_checks |
   map(.context) | sort | unique' \
  <<<"${ruleset_json}")"

mirror_contexts="$(jq --compact-output \
  '.rules[] | select(.type=="required_status_checks") |
   .parameters.required_status_checks |
   map(.context) | sort | unique' \
  <<<"${mirror_json}")"

if [[ ${live_contexts} != "${mirror_contexts}" ]]; then
  printf 'required-status-checks drift between live ruleset and in-tree mirror:\n' >&2
  printf '  live:   %s\n' "${live_contexts}" >&2
  printf '  mirror: %s\n' "${mirror_contexts}" >&2
  printf 'Symmetric diff:\n' >&2
  diff <(jq -r '.[]' <<<"${live_contexts}") <(jq -r '.[]' <<<"${mirror_contexts}") >&2 || true
  exit 1
fi

printf 'protect-main: live ruleset matches in-tree mirror (%d required checks)\n' \
  "$(jq 'length' <<<"${live_contexts}")"
