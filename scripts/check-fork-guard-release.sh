#!/usr/bin/env bash
# scripts/check-fork-guard-release.sh
#
# @description Lint: every workflow job holding a guard-required write
# scope (contents/packages/id-token/attestations/actions: write) carries
# a fork-guard `if:` pinning execution to the canonical repo.

# Lint: every workflow job that holds a guard-required write scope
# includes a fork-guard `if:` clause containing
# `github.repository == 'rvenutolo/linPEAS-flake'`.
#
# Guard-required write scopes (any of):
#   - contents: write       — push commits / tags / releases
#   - packages: write       — push container images / packages
#   - id-token: write       — mint OIDC tokens (cosign signing)
#   - attestations: write   — record SLSA attestations
#   - actions: write        — manage caches / cancel runs; a fork
#                             inheriting the workflow could prune or
#                             mutate the canonical repo's Actions cache
#                             namespace or cancel its runs if unguarded
#
# A job that mints a GitHub App installation token also counts as
# privileged even when it declares a read-only GITHUB_TOKEN: the App
# token carries real write privilege, letting the job commit, open
# PRs, and enable auto-merge through the App identity. Such a job is
# detected by a reference to the `actions/create-github-app-token`
# action or to the `secrets.BUMP_APP_PRIVATE_KEY` signing key, and
# must carry the fork guard the same as a write-scoped job.
#
# Without the guard, a fork that inherits these workflows can fire
# them under its own GITHUB_TOKEN (or repo-scoped secrets, if any
# were configured). The repository check pins execution to the
# canonical repo.
#
# A workflow-level guard isn't valid in GitHub Actions syntax (`if:`
# is job-scoped), so every guard-required job must carry the guard
# in its own `if:` expression. The lint matches the literal string
# `github.repository == 'rvenutolo/linPEAS-flake'`.
#
# See docs/security/workflow-hardening.md.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER for fixtures.
# REPO_SLUG_OVERRIDE swaps the expected slug for fixtures.
# Exits 0 on full coverage, 1 on any drift.

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/enumerate.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/enumerate.sh"

readonly DEFAULT_DIR=".github/workflows"
readonly DEFAULT_REPO_SLUG="rvenutolo/linPEAS-flake"
readonly OVERRIDE="${WORKFLOWS_DIR_OVERRIDE:-}"
readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
readonly DIR="${OVERRIDE:-${DEFAULT_DIR}}"
readonly REPO_SLUG="${REPO_SLUG_OVERRIDE:-${DEFAULT_REPO_SLUG}}"
readonly GUARD_NEEDLE="github.repository == '${REPO_SLUG}'"

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 2
fi

# Detect a guard-required write scope on one job. Returns 0 if found.
job_needs_fork_guard() {
  local -r file="$1" job="$2"
  for scope in contents packages id-token attestations actions; do
    local val
    val="$(yq eval ".jobs.\"${job}\".permissions.\"${scope}\" // \"\"" "${file}")"
    if [[ ${val} == "write" ]]; then
      return 0
    fi
  done
  # App installation token = real write privilege despite a read-only
  # GITHUB_TOKEN. A job minting one must carry the fork guard.
  local body
  body="$(yq eval ".jobs.\"${job}\"" "${file}")"
  [[ ${body} == *"actions/create-github-app-token"* ]] && return 0
  [[ ${body} == *"secrets.BUMP_APP_PRIVATE_KEY"* ]] && return 0
  return 1
}

failed=0
shopt -s nullglob
declare -a workflow_files=()
glob_into workflow_files 'workflow YAML' "${DIR}/*.yml" "${DIR}/*.yaml"
for f in "${workflow_files[@]}"; do
  [[ -f ${f} ]] || continue
  if [[ -n ${FILE_FILTER} && "$(basename "${f}")" != "${FILE_FILTER}" ]]; then
    continue
  fi

  # Capture yq's output (and exit status) into a variable rather than
  # feeding the loop from `< <(yq ...)`: a process substitution's exit
  # status is not propagated under set -Eeuo pipefail, so a yq failure
  # (unparsable workflow, or a query that errors on a valid-but-odd
  # shape) would yield empty input and the check would pass silently.
  if ! rows="$(yq eval '.jobs // {} | keys | .[]' "${f}")"; then
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi
  [[ -n ${rows} ]] || continue
  while IFS= read -r job; do
    [[ -z ${job} ]] && continue
    if ! job_needs_fork_guard "${f}" "${job}"; then
      continue
    fi
    if_clause="$(yq eval ".jobs.\"${job}\".if // \"\"" "${f}")"
    if [[ ${if_clause} != *"${GUARD_NEEDLE}"* ]]; then
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      printf '%s: job %q holds guard-required write scope but is missing fork guard `%s`; got if=%q\n' \
        "${f}" "${job}" "${GUARD_NEEDLE}" "${if_clause}" >&2
      failed=$((failed + 1))
    fi
  done <<<"${rows}"
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d guard-required job(s) missing fork guard\n' "${failed}" >&2
  exit 1
fi
exit 0
