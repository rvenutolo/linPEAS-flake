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
# Exits 2 when the check cannot run: an input (the in-tree mirror, the
# required-checks doc, or the ruleset JSON) is absent, unreadable, or
# otherwise cannot be read — or the ruleset JSON reads but cannot be read
# as a ruleset, e.g. `.rules` is present but is not an array, so
# `.rules[].type` errors. A tooling fault must not borrow the drift code:
# that reads as a substantive ruleset change and sends a maintainer after
# a rule nobody removed. An absent `.rules` is not a tooling fault — it
# is an empty rule list, i.e. drift.
#
# Env overrides (test-only):
#   PROTECT_MAIN_RULESET_JSON_OVERRIDE — path to a fixture JSON for the live
#                                        ruleset. Named for the ruleset this
#                                        lint reads, because a sibling lint
#                                        reads a different ruleset through the
#                                        same API route and one variable shared
#                                        between them would feed a single
#                                        fixture to both whenever one process
#                                        runs the pair.
#   MIRROR_JSON_OVERRIDE               — path to a fixture JSON for the in-tree
#                                        mirror
#   DOC_TABLE_OVERRIDE                 — path to a fixture markdown doc for the
#                                        required-checks table

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

# The ruleset comes from the API, so an absent `gh` means nothing was
# read. Unguarded it exits 1, telling a caller the ruleset drifted.
require_tool gh

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

# @description Fetch the live ruleset JSON from the rulesets API.
# Both calls are status-checked. `gh` present but failing — an API
# error, an expired token, no network — exits 1, and an unchecked
# assignment hands that 1 to the caller as this check's own verdict,
# which reads as a drifted ruleset rather than as a fetch that never
# happened. An empty ruleset list is a different answer: the API
# answered, and no ruleset by this name is a finding about the repo.
function fetch_ruleset() {
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

# The mirror payload is either a fixture path or the in-tree file, and
# every read below assumes a shape neither source guarantees.
payload_source_into mirror_source MIRROR_JSON_OVERRIDE \
  '.github/rulesets/protect-main.json'
readonly mirror_source
read_json_payload_into mirror_json "${MIRROR_FILE}" "${mirror_source}" \
  'protect-main mirror'
readonly mirror_json

# The required-checks doc is markdown, not JSON, so it does not go
# through read_json_payload_into — it keeps its own not-found guard and
# gets its own readability guard beside it.
if [[ ! -f ${DOC_FILE} ]]; then
  printf 'required-checks doc not found: %s\n' "${DOC_FILE}" >&2
  exit 2
fi
if [[ ! -r ${DOC_FILE} ]]; then
  printf 'required-checks doc is not readable: %s\n' "${DOC_FILE}" >&2
  exit 2
fi

# --- doc-table parity with in-tree mirror ------------------------------------
# Contexts in the mirror must match the first column of the
# `## Required contexts` table in docs/security/required-checks.md.
# Runs before the live-ruleset fetch so the doc half also fails
# offline (and under fixture overrides without a live fixture).

# The payload gate above proves the mirror parses, not that it carries a
# required_status_checks rule shaped the way this read walks it. A `jq`
# that dies on the walk has read no context list, and its own status
# would surface as a doc-table drift verdict below.
if ! mirror_contexts="$(jq --compact-output \
  '.rules[] | select(.type=="required_status_checks") |
  .parameters.required_status_checks |
  map(.context) | sort | unique' \
  <<<"${mirror_json}")"; then
  log_err "cannot read required_status_checks contexts from ${mirror_source}"
  exit 2
fi

if ! doc_contexts="$(awk --field-separator='|' '
  /^## Required contexts$/ { in_section = 1; next }
  in_section && /^## / { in_section = 0 }
  in_section && /^\|/ {
    cell = $2
    gsub(/^[ \t]+|[ \t]+$/, "", cell)
    if (cell != "Context" && cell !~ /^-+$/ && cell != "") { print cell }
  }
' "$(awk_path "${DOC_FILE}")" | jq --raw-input . | jq --slurp --compact-output 'sort | unique')"; then
  log_err "cannot read the required-contexts table from ${DOC_FILE}"
  exit 2
fi

if [[ ${doc_contexts} != "${mirror_contexts}" ]]; then
  printf 'doc-table drift between required-checks.md and in-tree mirror:\n' >&2
  printf '  doc:    %s\n' "${doc_contexts}" >&2
  printf '  mirror: %s\n' "${mirror_contexts}" >&2
  printf 'Symmetric diff:\n' >&2
  diff <(jq -r '.[]' <<<"${doc_contexts}") <(jq -r '.[]' <<<"${mirror_contexts}") >&2 || true
  exit 1
fi

# The ruleset payload is either a fixture path or the rulesets API's
# response, and every read below assumes a shape neither source
# guarantees.
payload_source_into ruleset_source PROTECT_MAIN_RULESET_JSON_OVERRIDE \
  "/repos/${THIS_REPO}/rulesets/{id}"
readonly ruleset_source

# read_json_payload_into fills a nameref, so it must run in this shell —
# never inside `$(...)`, where its `exit 2` would be trapped in a
# subshell and this script would carry on with an empty ruleset_json.
# That is why the override branch is hoisted out of fetch_ruleset rather
# than living inside it.
if [[ -n ${PROTECT_MAIN_RULESET_JSON_OVERRIDE:-} ]]; then
  read_json_payload_into ruleset_json "${PROTECT_MAIN_RULESET_JSON_OVERRIDE}" \
    "${ruleset_source}" "${EXPECTED_NAME} ruleset"
else
  ruleset_json="$(fetch_ruleset)"
fi

# The subject is passed because the source kind alone does not identify this
# payload: a sibling lint reads a different ruleset through the same API
# route.
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
  # The verdict is exit 1, so the diagnostic beside it must not decide the
  # status: bare, a jq that cannot render the field ends the run under jq's
  # own code — 5 on a payload it cannot parse — in place of the violation
  # this branch found. A diagnostic that could not be printed is not a
  # reason to withhold the finding.
  jq '.bypass_actors' <<<"${ruleset_json}" >&2 || log_err 'could not render bypass_actors'
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
  if ((found == 0)); then
    printf 'missing rule: %s (have: %s)\n' "${required}" "${actual_rules[*]}" >&2
    exit 1
  fi
done

# --- pull_request rule: allowed_merge_methods == ["merge"] ------------------

if ! merge_methods="$(jq --compact-output \
  '.rules[] | select(.type=="pull_request") | .parameters.allowed_merge_methods' \
  <<<"${ruleset_json}")"; then
  log_err "cannot read allowed_merge_methods from ${ruleset_source}"
  exit 2
fi
if [[ ${merge_methods} != "${EXPECTED_MERGE_METHODS}" ]]; then
  printf 'allowed_merge_methods drift: got %s, want %s\n' \
    "${merge_methods}" "${EXPECTED_MERGE_METHODS}" >&2
  exit 1
fi

# --- pull_request rule: required_review_thread_resolution == true ----------

if ! thread_resolution="$(jq --raw-output \
  '.rules[] | select(.type=="pull_request") |
  .parameters.required_review_thread_resolution' \
  <<<"${ruleset_json}")"; then
  log_err "cannot read required_review_thread_resolution from ${ruleset_source}"
  exit 2
fi
if [[ ${thread_resolution} != 'true' ]]; then
  printf 'required_review_thread_resolution drift: got %q, want true\n' \
    "${thread_resolution}" >&2
  exit 1
fi

# --- required_status_checks rule: strict policy == true --------------------

if ! strict_policy="$(jq --raw-output \
  '.rules[] | select(.type=="required_status_checks") |
  .parameters.strict_required_status_checks_policy' \
  <<<"${ruleset_json}")"; then
  log_err "cannot read strict_required_status_checks_policy from ${ruleset_source}"
  exit 2
fi
if [[ ${strict_policy} != 'true' ]]; then
  printf 'strict_required_status_checks_policy drift: got %q, want true\n' \
    "${strict_policy}" >&2
  exit 1
fi

# --- required-status-checks parity with in-tree mirror ----------------------
# Context-set diff: sort by context, compare the context list (mirror_contexts
# was computed for the doc-table check above). integration_id is verified
# separately in the block that follows.

if ! live_contexts="$(jq --compact-output \
  '.rules[] | select(.type=="required_status_checks") |
  .parameters.required_status_checks |
  map(.context) | sort | unique' \
  <<<"${ruleset_json}")"; then
  log_err "cannot read required_status_checks contexts from ${ruleset_source}"
  exit 2
fi

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

if ! mirror_tuples="$(jq --compact-output \
  '.rules[] | select(.type=="required_status_checks") |
  .parameters.required_status_checks |
  map({context, integration_id: (.integration_id // null)}) |
  sort_by(.context)' \
  <<<"${mirror_json}")"; then
  log_err "cannot read context/integration_id pairs from ${mirror_source}"
  exit 2
fi

if ! live_tuples="$(jq --compact-output \
  '.rules[] | select(.type=="required_status_checks") |
  .parameters.required_status_checks |
  map({context, integration_id: (.integration_id // null)}) |
  sort_by(.context)' \
  <<<"${ruleset_json}")"; then
  log_err "cannot read context/integration_id pairs from ${ruleset_source}"
  exit 2
fi

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
