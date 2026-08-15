#!/usr/bin/env bash
# scripts/check-settings-posture.sh
#
# @description Lint: every gh-API-verifiable row in
# `docs/security/settings-posture.md` matches the live repository
# configuration. Manual-UI rows are out of scope.

# Lint: assert every gh-API-verifiable row in
# `docs/security/settings-posture.md` matches the live (or
# fixture-injected) repository configuration.
#
# Closes the gap where settings-posture.md was the source-of-truth for
# binding repo flags but had no CI drift check. The manual-UI rows
# (fork-PR approval gate, maintainer 2FA, merge-method flags) are
# intentionally not covered. GitHub exposes no REST endpoint for the
# first two. The merge-method flags on `GET /repos/{owner}/{repo}`
# (allow_*_merge, merge_commit_*, delete_branch_on_merge,
# allow_update_branch) are returned by GitHub only to identities with
# `contents: read` AND `contents: write` — i.e. push access. The
# settings-drift-checker App is read-only by construction (Admin:Read +
# Metadata:Read) and must remain so; granting contents:write would let
# its installation token push arbitrary code. Merge-method posture is
# verified at PR-merge time instead: the merge-commit ruleset rejects
# rebase/squash merges, and `pr-title-lint` enforces the title shape
# `merge_commit_title=PR_TITLE` relies on.
#
# Exits 0 on full match, 1 on any drift. Logs the specific drift to
# stderr.
#
# Env overrides (test-only): each points at a fixture JSON capturing
# the response shape of one API endpoint.
#   REPO_JSON_OVERRIDE                    — /repos/{owner}/{repo}
#   ACTIONS_PERMS_JSON_OVERRIDE           — /repos/{owner}/{repo}/actions/permissions
#   ACTIONS_WORKFLOW_PERMS_JSON_OVERRIDE  — /repos/{owner}/{repo}/actions/permissions/workflow
#   ENV_GITHUB_PAGES_JSON_OVERRIDE        — /repos/{owner}/{repo}/environments/github-pages

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/payload.sh
source "${_lib_dir}/lib/payload.sh"

readonly THIS_REPO='rvenutolo/linPEAS-flake'

drift_count=0

# @description Report a drift line and bump the counter without exiting.
# Surfacing every mismatch in one run is more useful than failing on
# the first; a UI flip often toggles several settings at once.
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

# @description Fetch a JSON document either from an override fixture
# or via `gh api`.
# @arg $1 override env var name
# @arg $2 API path
function fetch_json() {
  local -r override_var="$1"
  local -r api_path="$2"
  # Resolved by indirect expansion so this reader and the source namer
  # honor the same set of variables. An env-only reader paired with a
  # scope-agnostic namer would name a source the fetch did not use. The
  # resolved value is bound to a local so the ERR trap, which echoes
  # BASH_COMMAND, names the failing read by the path it used rather than
  # by the indirection that produced it.
  local -r override="${!override_var:-}"
  if [[ -n ${override} ]]; then
    cat -- "${override}"
    return
  fi
  gh api --header 'X-GitHub-Api-Version: 2022-11-28' -- "${api_path}"
}

# @description Read a `.path.to.field` from JSON and compare it to an
# expected literal. Reports drift if mismatched.
# @arg $1 JSON document
# @arg $2 jq path
# @arg $3 expected value (string compared after --raw-output)
# @arg $4 setting key (for the drift message)
function assert_field() {
  local -r json="$1"
  local -r path="$2"
  local -r want="$3"
  local -r key="$4"
  local got
  got="$(jq --raw-output -- "${path}" <<<"${json}")"
  if [[ ${got} != "${want}" ]]; then
    report_drift "${key}" "${got}" "${want}"
  fi
}

repo_json="$(fetch_json REPO_JSON_OVERRIDE "/repos/${THIS_REPO}")"
payload_source_into repo_source REPO_JSON_OVERRIDE "/repos/${THIS_REPO}"
readonly repo_source
require_json_payload "${repo_source}" "${repo_json}" '
  if type != "object" then "payload is \(type), want object"
  elif (.security_and_analysis | type) != "object" then ".security_and_analysis is \(.security_and_analysis | type), want object"
  else empty
  end'

actions_perms_json="$(fetch_json ACTIONS_PERMS_JSON_OVERRIDE \
  "/repos/${THIS_REPO}/actions/permissions")"
payload_source_into actions_perms_source ACTIONS_PERMS_JSON_OVERRIDE \
  "/repos/${THIS_REPO}/actions/permissions"
readonly actions_perms_source
require_json_payload "${actions_perms_source}" "${actions_perms_json}" '
  if type != "object" then "payload is \(type), want object"
  elif (.allowed_actions | type) != "string" then ".allowed_actions is \(.allowed_actions | type), want string"
  elif (.sha_pinning_required | type) != "boolean" then ".sha_pinning_required is \(.sha_pinning_required | type), want boolean"
  else empty
  end'

actions_workflow_perms_json="$(fetch_json ACTIONS_WORKFLOW_PERMS_JSON_OVERRIDE \
  "/repos/${THIS_REPO}/actions/permissions/workflow")"
payload_source_into actions_workflow_perms_source ACTIONS_WORKFLOW_PERMS_JSON_OVERRIDE \
  "/repos/${THIS_REPO}/actions/permissions/workflow"
readonly actions_workflow_perms_source
require_json_payload "${actions_workflow_perms_source}" "${actions_workflow_perms_json}" '
  if type != "object" then "payload is \(type), want object"
  elif (.default_workflow_permissions | type) != "string" then ".default_workflow_permissions is \(.default_workflow_permissions | type), want string"
  elif (.can_approve_pull_request_reviews | type) != "boolean" then ".can_approve_pull_request_reviews is \(.can_approve_pull_request_reviews | type), want boolean"
  else empty
  end'

env_github_pages_json="$(fetch_json ENV_GITHUB_PAGES_JSON_OVERRIDE \
  "/repos/${THIS_REPO}/environments/github-pages")"
payload_source_into env_github_pages_source ENV_GITHUB_PAGES_JSON_OVERRIDE \
  "/repos/${THIS_REPO}/environments/github-pages"
readonly env_github_pages_source
require_json_payload "${env_github_pages_source}" "${env_github_pages_json}" '
  if type != "object" then "payload is \(type), want object"
  elif (.can_admins_bypass | type) != "boolean" then ".can_admins_bypass is \(.can_admins_bypass | type), want boolean"
  else empty
  end'

# --- Security & analysis ----------------------------------------------------

assert_field "${repo_json}" \
  '.security_and_analysis.secret_scanning.status' \
  'enabled' \
  'secret_scanning.status'
assert_field "${repo_json}" \
  '.security_and_analysis.secret_scanning_push_protection.status' \
  'enabled' \
  'secret_scanning_push_protection.status'
assert_field "${repo_json}" \
  '.security_and_analysis.dependabot_security_updates.status' \
  'enabled' \
  'dependabot_security_updates.status'

# --- Actions permissions ----------------------------------------------------

assert_field "${actions_perms_json}" '.allowed_actions' 'selected' 'allowed_actions'
assert_field "${actions_perms_json}" '.sha_pinning_required' 'true' 'sha_pinning_required'

# --- Workflow permissions ---------------------------------------------------

assert_field "${actions_workflow_perms_json}" \
  '.default_workflow_permissions' 'read' 'default_workflow_permissions'
assert_field "${actions_workflow_perms_json}" \
  '.can_approve_pull_request_reviews' 'false' 'can_approve_pull_request_reviews'

# --- Environments -----------------------------------------------------------

assert_field "${env_github_pages_json}" \
  '.can_admins_bypass' 'false' 'environments.github-pages.can_admins_bypass'

if ((drift_count > 0)); then
  printf '\n%d setting(s) drifted from docs/security/settings-posture.md\n' \
    "${drift_count}" >&2
  exit 1
fi

printf 'settings-posture: live repo configuration matches docs/security/settings-posture.md\n'
