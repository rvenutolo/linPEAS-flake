#!/usr/bin/env bash
# scripts/check-allowed-actions-api.sh
#
# @description Assert the live `actions.permissions.allowed_actions`
# API state matches the canonical allowlist documented in
# `docs/security/allowed-actions.md`.

# Lint: assert the live `actions.permissions.allowed_actions` API state
# matches the canonical allowlist documented at
# `docs/security/allowed-actions.md`.
#
# Workflow-YAML linting (scripts/check-uses-sha-pinned.sh) only catches
# new `uses:` strings; it cannot see an API-level vendor expansion
# (someone clicking "Approve" on an unlisted vendor in repo Settings →
# Actions, or a GitHub-side default shift) until a workflow happens to
# call the newly-allowed vendor. This script closes that gap by
# probing the API directly.
#
# Exits 0 on full match, 1 on any drift, 2 when the comparison could not
# be made at all: `gh` or `jq` is absent from PATH, the allowlist doc is
# missing or its canonical fenced block yields no patterns, the live API
# call fails, or the selected-actions payload is missing a field this
# check reads or carries it at the wrong type. Without the doc there is
# no expected side to compare against, so reporting drift would send a
# maintainer to the live API state when the doc is what needs fixing.
# Logs the specific drift to stderr.
#
# Env overrides (test-only):
#   SELECTED_ACTIONS_JSON_OVERRIDE — path to fixture JSON for
#     /repos/{owner}/{repo}/actions/permissions/selected-actions
#   ALLOWED_ACTIONS_DOC_OVERRIDE   — path to a fixture markdown doc
#     supplying the canonical patterns_allowed list

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

# The API read below is this check's only source of truth. An absent
# `gh` would otherwise end the run under the tool's own status, which
# the exit-code convention does not catalogue.
require_tool gh

readonly THIS_REPO='rvenutolo/linPEAS-flake'

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf '.')"
readonly REPO_ROOT
readonly DOC_FILE="${ALLOWED_ACTIONS_DOC_OVERRIDE:-${REPO_ROOT}/docs/security/allowed-actions.md}"

# @description Extract the canonical allowlist from the doc. The doc
# contains exactly one fenced ```text block under the "## Allowlist
# (canonical)" heading; each non-blank line inside is one pattern.
# @arg $1 path to doc
function extract_doc_patterns() {
  local -r doc="$1"
  if [[ ! -f ${doc} ]]; then
    printf 'allowed-actions doc not found: %s\n' "${doc}" >&2
    exit 2
  fi
  if [[ ! -r ${doc} ]]; then
    printf 'allowed-actions doc is not readable: %s\n' "${doc}" >&2
    exit 2
  fi
  # POSIX-awk: emit lines between the first ```text fence and the
  # matching close fence after the "## Allowlist (canonical)" heading.
  awk '
    BEGIN { in_section = 0; in_block = 0 }
    /^## Allowlist \(canonical\)[[:space:]]*$/ { in_section = 1; next }
    in_section && /^```text[[:space:]]*$/      { in_block = 1; next }
    in_section && in_block && /^```[[:space:]]*$/ { exit }
    in_section && in_block {
      sub(/[[:space:]]+$/, "")
      if (length($0) > 0) print $0
    }
  ' "$(awk_path "${doc}")"
}

# @description Fetch the live selected-actions API state.
function fetch_selected_actions() {
  gh api --header 'X-GitHub-Api-Version: 2022-11-28' \
    -- "/repos/${THIS_REPO}/actions/permissions/selected-actions"
}

drift_count=0

# @description Report drift line + bump counter.
# @arg $1 setting key
# @arg $2 actual value
# @arg $3 expected value
function report_drift() {
  local -r key="$1"
  local -r got="$2"
  local -r want="$3"
  printf '%s drift: got %q, want %q\n' "${key}" "${got}" "${want}" >&2
  drift_count=$((drift_count + 1))
}

doc_patterns_sorted="$(extract_doc_patterns "${DOC_FILE}" | LC_ALL=C sort --unique)"
if [[ -z ${doc_patterns_sorted} ]]; then
  printf 'extracted empty allowlist from %s — check fenced-block markers\n' \
    "${DOC_FILE}" >&2
  exit 2
fi

# The selected-actions payload is either a fixture path or the
# selected-actions API's response, and every read below assumes a shape
# neither source guarantees. `.patterns_allowed` has no `has()` guard in
# the shape program below: the read that follows iterates it with
# `.patterns_allowed[]` and no `// []` fallback, so an absent field would
# crash that read the same as a wrong-typed one.
payload_source_into selected_source SELECTED_ACTIONS_JSON_OVERRIDE \
  "/repos/${THIS_REPO}/actions/permissions/selected-actions"
readonly selected_source

# read_json_payload_into fills a nameref, so it must run in this shell —
# never inside `$(...)`, where its `exit 2` would be trapped in a
# subshell and this script would carry on with an empty selected_json.
# That is why the override branch is hoisted out of
# fetch_selected_actions rather than living inside it.
if [[ -n ${SELECTED_ACTIONS_JSON_OVERRIDE:-} ]]; then
  read_json_payload_into selected_json "${SELECTED_ACTIONS_JSON_OVERRIDE}" \
    "${selected_source}"
elif ! selected_json="$(fetch_selected_actions)"; then
  # `gh` is on PATH — an absent one is reported by the guard above — so a
  # failure here is the API refusing, the token expiring, or the network
  # being gone. Unchecked, `gh`'s own exit 1 would surface as this
  # check's verdict and read as an allowlist that drifted, when nothing
  # about the live allowlist was read at all.
  log_err "cannot fetch ${selected_source}: GitHub API call failed"
  exit 2
fi

require_json_payload "${selected_source}" "${selected_json}" '
  if type != "object" then "payload is \(type), want object"
  elif (.github_owned_allowed | type) != "boolean" then ".github_owned_allowed is \(.github_owned_allowed | type), want boolean"
  elif (.verified_allowed | type) != "boolean" then ".verified_allowed is \(.verified_allowed | type), want boolean"
  elif (.patterns_allowed | type) != "array" then ".patterns_allowed is \(.patterns_allowed | type), want array"
  else empty
  end'

# --- github_owned_allowed must be true --------------------------------------

github_owned="$(jq --raw-output '.github_owned_allowed' <<<"${selected_json}")"
if [[ ${github_owned} != "true" ]]; then
  report_drift 'github_owned_allowed' "${github_owned}" 'true'
fi

# --- verified_allowed must be false -----------------------------------------

verified="$(jq --raw-output '.verified_allowed' <<<"${selected_json}")"
if [[ ${verified} != "false" ]]; then
  report_drift 'verified_allowed' "${verified}" 'false'
fi

# --- patterns_allowed must match the doc exactly ----------------------------

live_patterns_sorted="$(
  jq --raw-output '.patterns_allowed[]' <<<"${selected_json}" |
    LC_ALL=C sort --unique
)"

# Use comm to find symmetric diff. -23 = only in live; -13 = only in doc.
only_in_live="$(comm -23 \
  <(printf '%s\n' "${live_patterns_sorted}") \
  <(printf '%s\n' "${doc_patterns_sorted}"))"
only_in_doc="$(comm -13 \
  <(printf '%s\n' "${live_patterns_sorted}") \
  <(printf '%s\n' "${doc_patterns_sorted}"))"

if [[ -n ${only_in_live} ]]; then
  while IFS= read -r pattern; do
    [[ -z ${pattern} ]] && continue
    # %s not %q for patterns: glob chars like `*` would be escaped by
    # %q, obscuring the recognizable vendor pattern.
    printf 'patterns_allowed drift: extra on API: %s (not in docs/security/allowed-actions.md)\n' \
      "${pattern}" >&2
    drift_count=$((drift_count + 1))
  done <<<"${only_in_live}"
fi

if [[ -n ${only_in_doc} ]]; then
  while IFS= read -r pattern; do
    [[ -z ${pattern} ]] && continue
    printf 'patterns_allowed drift: missing on API: %s (declared in docs/security/allowed-actions.md but not in live state)\n' \
      "${pattern}" >&2
    drift_count=$((drift_count + 1))
  done <<<"${only_in_doc}"
fi

if ((drift_count > 0)); then
  printf '\n%d allowlist drift(s) from docs/security/allowed-actions.md\n' \
    "${drift_count}" >&2
  exit 1
fi

printf 'allowed-actions: live patterns_allowed matches docs/security/allowed-actions.md (%d patterns)\n' \
  "$(printf '%s\n' "${doc_patterns_sorted}" | wc -l)"
