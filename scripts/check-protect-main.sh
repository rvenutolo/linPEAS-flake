#!/usr/bin/env bash
# scripts/check-protect-main.sh
#
# @description Lint: the live `protect-main` branch ruleset matches
# the desired posture, the in-tree mirror at
# `.github/rulesets/protect-main.json`, and the `## Required contexts`
# table in `docs/security/required-checks.md`.

# Lint: assert the live (or fixture-injected) `protect-main` branch
# ruleset matches the desired posture AND the in-tree mirror at
# `.github/rulesets/protect-main.json`, AND that the mirror's
# required-status-check contexts match the `## Required contexts`
# table in `docs/security/required-checks.md` (a documented-but-not-
# enforced context — or an enforced-but-undocumented one — is drift).
#
# Mirrors the pattern in scripts/check-tag-protection.sh, closing the
# asymmetry where the tag-protection ruleset had a CI drift check but
# the branch-protection ruleset relied on review discipline alone.
#
# Asserted invariants:
#   - mirror required-status-check contexts match the doc table
#     (runs before any network call so it also fails offline)
#   - ruleset name `protect-main`
#   - target `branch`, enforcement `active`
#   - conditions.ref_name.include == ["~DEFAULT_BRANCH"]
#   - bypass_actors == []
#   - rules include `deletion`, `non_fast_forward`, `required_signatures`
#   - pull_request rule allowed_merge_methods == ["merge"]
#   - pull_request rule required_review_thread_resolution == true
#   - required_status_checks rule strict_required_status_checks_policy
#     == true
#   - required-status-checks set matches the in-tree mirror (context set,
#     sorted)
#   - each required context pins the same integration_id live-vs-mirror
#     (absent normalized to null; a stripped/repointed id is drift)
#
# Exits 0 on match, 1 on drift. Logs the specific drift to stderr.
# Exits 2 when the check cannot run: an input file is absent (the
# in-tree mirror or the required-checks doc), or the ruleset JSON cannot
# be read at all — e.g. `.rules` is present but is not an array, so
# `.rules[].type` errors. A tooling fault must not borrow the drift code:
# that reads as a substantive ruleset change and sends a maintainer after
# a rule nobody removed. An absent `.rules` is not a tooling fault — it
# is an empty rule list, i.e. drift.
#
# Env overrides (test-only):
#   RULESET_JSON_OVERRIDE — path to a fixture JSON for the live ruleset
#   MIRROR_JSON_OVERRIDE  — path to a fixture JSON for the in-tree mirror
#   DOC_TABLE_OVERRIDE    — path to a fixture markdown doc for the
#                           required-checks table

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "${_lib_dir}/lib/awk-path.sh"
# shellcheck source=scripts/lib/payload.sh
source "${_lib_dir}/lib/payload.sh"

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
readonly DOC_FILE="${DOC_TABLE_OVERRIDE:-${REPO_ROOT}/docs/security/required-checks.md}"

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
  exit 2
fi
if [[ ! -f ${DOC_FILE} ]]; then
  printf 'required-checks doc not found: %s\n' "${DOC_FILE}" >&2
  exit 2
fi

mirror_json="$(cat -- "${MIRROR_FILE}")"

# --- doc-table parity with in-tree mirror ------------------------------------
# Contexts in the mirror must match the first column of the
# `## Required contexts` table in docs/security/required-checks.md.
# Runs before the live-ruleset fetch so the doc half also fails
# offline (and under fixture overrides without a live fixture).

mirror_contexts="$(jq --compact-output \
  '.rules[] | select(.type=="required_status_checks") |
  .parameters.required_status_checks |
  map(.context) | sort | unique' \
  <<<"${mirror_json}")"

doc_contexts="$(awk --field-separator='|' '
  /^## Required contexts$/ { in_section = 1; next }
  in_section && /^## / { in_section = 0 }
  in_section && /^\|/ {
    cell = $2
    gsub(/^[ \t]+|[ \t]+$/, "", cell)
    if (cell != "Context" && cell !~ /^-+$/ && cell != "") { print cell }
  }
' "$(awk_path "${DOC_FILE}")" | jq --raw-input . | jq --slurp --compact-output 'sort | unique')"

if [[ ${doc_contexts} != "${mirror_contexts}" ]]; then
  printf 'doc-table drift between required-checks.md and in-tree mirror:\n' >&2
  printf '  doc:    %s\n' "${doc_contexts}" >&2
  printf '  mirror: %s\n' "${mirror_contexts}" >&2
  printf 'Symmetric diff:\n' >&2
  diff <(jq -r '.[]' <<<"${doc_contexts}") <(jq -r '.[]' <<<"${mirror_contexts}") >&2 || true
  exit 1
fi

ruleset_json="$(fetch_ruleset)"

# The ruleset payload is either a fixture path or the rulesets API's
# response, and every read below assumes a shape neither source
# guarantees. Name the source by kind, never by fixture path, so a
# malformed payload is reported as a could-not-run instead of raw jq
# noise or drift nobody caused.
if [[ -n ${RULESET_JSON_OVERRIDE:-} ]]; then
  ruleset_source='RULESET_JSON_OVERRIDE'
else
  ruleset_source="/repos/${THIS_REPO}/rulesets/{id}"
fi
readonly ruleset_source

# The subject is passed because the source kind alone does not identify this
# payload: a sibling lint reads a different ruleset through the same override
# variable and the same API route.
require_json_payload "${ruleset_source}" "${ruleset_json}" '
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

# --- pull_request rule: allowed_merge_methods == ["merge"] ------------------

merge_methods="$(jq --compact-output \
  '.rules[] | select(.type=="pull_request") | .parameters.allowed_merge_methods' \
  <<<"${ruleset_json}")"
if [[ ${merge_methods} != "${EXPECTED_MERGE_METHODS}" ]]; then
  printf 'allowed_merge_methods drift: got %s, want %s\n' \
    "${merge_methods}" "${EXPECTED_MERGE_METHODS}" >&2
  exit 1
fi

# --- pull_request rule: required_review_thread_resolution == true ----------

thread_resolution="$(jq --raw-output \
  '.rules[] | select(.type=="pull_request") |
  .parameters.required_review_thread_resolution' \
  <<<"${ruleset_json}")"
if [[ ${thread_resolution} != 'true' ]]; then
  printf 'required_review_thread_resolution drift: got %q, want true\n' \
    "${thread_resolution}" >&2
  exit 1
fi

# --- required_status_checks rule: strict policy == true --------------------

strict_policy="$(jq --raw-output \
  '.rules[] | select(.type=="required_status_checks") |
  .parameters.strict_required_status_checks_policy' \
  <<<"${ruleset_json}")"
if [[ ${strict_policy} != 'true' ]]; then
  printf 'strict_required_status_checks_policy drift: got %q, want true\n' \
    "${strict_policy}" >&2
  exit 1
fi

# --- required-status-checks parity with in-tree mirror ----------------------
# Context-set diff: sort by context, compare the context list (mirror_contexts
# was computed for the doc-table check above). integration_id is verified
# separately in the block that follows.

live_contexts="$(jq --compact-output \
  '.rules[] | select(.type=="required_status_checks") |
  .parameters.required_status_checks |
  map(.context) | sort | unique' \
  <<<"${ruleset_json}")"

if [[ ${live_contexts} != "${mirror_contexts}" ]]; then
  printf 'required-status-checks drift between live ruleset and in-tree mirror:\n' >&2
  printf '  live:   %s\n' "${live_contexts}" >&2
  printf '  mirror: %s\n' "${mirror_contexts}" >&2
  printf 'Symmetric diff:\n' >&2
  diff <(jq -r '.[]' <<<"${live_contexts}") <(jq -r '.[]' <<<"${mirror_contexts}") >&2 || true
  exit 1
fi

# --- integration_id parity with in-tree mirror ------------------------------
# Context set already verified above. Now verify each context pins the same
# integration_id live-vs-mirror (absent normalized to null) so a stripped or
# repointed integration_id — which would let a non-Actions reporter satisfy a
# provenance check — is flagged.

mirror_tuples="$(jq --compact-output \
  '.rules[] | select(.type=="required_status_checks") |
  .parameters.required_status_checks |
  map({context, integration_id: (.integration_id // null)}) |
  sort_by(.context)' \
  <<<"${mirror_json}")"

live_tuples="$(jq --compact-output \
  '.rules[] | select(.type=="required_status_checks") |
  .parameters.required_status_checks |
  map({context, integration_id: (.integration_id // null)}) |
  sort_by(.context)' \
  <<<"${ruleset_json}")"

if [[ ${live_tuples} != "${mirror_tuples}" ]]; then
  printf 'integration_id drift between live ruleset and in-tree mirror:\n' >&2
  printf '  live:   %s\n' "${live_tuples}" >&2
  printf '  mirror: %s\n' "${mirror_tuples}" >&2
  printf 'Symmetric diff:\n' >&2
  diff \
    <(jq -r '.[] | "\(.context)\t\(.integration_id)"' <<<"${live_tuples}") \
    <(jq -r '.[] | "\(.context)\t\(.integration_id)"' <<<"${mirror_tuples}") >&2 || true
  exit 1
fi

printf 'protect-main: live ruleset matches in-tree mirror (%d required checks)\n' \
  "$(jq 'length' <<<"${live_contexts}")"
