#!/usr/bin/env bash
# scripts/check-settings-posture.sh
#
# Lint: assert every gh-API-verifiable row in
# `docs/security/settings-posture.md` matches the live (or
# fixture-injected) repository configuration.
#
# Closes the gap where settings-posture.md was the source-of-truth for
# binding repo flags but had no CI drift check. The manual-UI rows
# (fork-PR approval gate, maintainer 2FA) are intentionally not
# covered: GitHub exposes no REST endpoint for either.
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
  local override
  override="$(printenv -- "${override_var}" 2>/dev/null || printf '')"
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
actions_perms_json="$(fetch_json ACTIONS_PERMS_JSON_OVERRIDE \
  "/repos/${THIS_REPO}/actions/permissions")"
actions_workflow_perms_json="$(fetch_json ACTIONS_WORKFLOW_PERMS_JSON_OVERRIDE \
  "/repos/${THIS_REPO}/actions/permissions/workflow")"
env_github_pages_json="$(fetch_json ENV_GITHUB_PAGES_JSON_OVERRIDE \
  "/repos/${THIS_REPO}/environments/github-pages")"

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

# --- Merge method -----------------------------------------------------------

assert_field "${repo_json}" '.allow_merge_commit' 'true' 'allow_merge_commit'
assert_field "${repo_json}" '.allow_rebase_merge' 'false' 'allow_rebase_merge'
assert_field "${repo_json}" '.allow_squash_merge' 'false' 'allow_squash_merge'
assert_field "${repo_json}" '.allow_auto_merge' 'true' 'allow_auto_merge'
assert_field "${repo_json}" '.allow_update_branch' 'true' 'allow_update_branch'
assert_field "${repo_json}" '.delete_branch_on_merge' 'true' 'delete_branch_on_merge'
assert_field "${repo_json}" '.merge_commit_title' 'PR_TITLE' 'merge_commit_title'
assert_field "${repo_json}" '.merge_commit_message' 'PR_BODY' 'merge_commit_message'

# --- Environments -----------------------------------------------------------

assert_field "${env_github_pages_json}" \
  '.can_admins_bypass' 'false' 'environments.github-pages.can_admins_bypass'

if ((drift_count > 0)); then
  printf '\n%d setting(s) drifted from docs/security/settings-posture.md\n' \
    "${drift_count}" >&2
  exit 1
fi

printf 'settings-posture: live repo configuration matches docs/security/settings-posture.md\n'
