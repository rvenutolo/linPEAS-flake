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
#   - actions: write        — manage caches / re-run runs; a fork
#                             inheriting the workflow would fire it under
#                             the fork's own token, deleting the fork's
#                             caches and re-running its failed jobs on a
#                             schedule its owner never asked for
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
# GitHub Actions reads a workflow file as one YAML document and refuses
# one holding several, so a file that `yq` reads as several is a finding
# and its jobs are not read. A failure of that first read, or of the
# read listing the jobs, is a counted finding too.
#
# See docs/security/workflow-hardening.md.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER for fixtures.
# REPO_SLUG_OVERRIDE swaps the expected slug for fixtures.
# Exits 0 on full coverage, 1 on any drift. Exits 2 when the check
# cannot run: `yq` is absent from PATH, the workflow globs match no
# file, WORKFLOW_FILE_FILTER selects none of the files they matched, or
# a read of one job's permissions, body or `if:` fails once the job list
# has been read. An empty scan set is a could-not-run rather than a clean tree;
# LINT_ALLOW_EMPTY_SCAN=1 accepts one deliberately.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"

readonly DEFAULT_DIR=".github/workflows"
readonly DEFAULT_REPO_SLUG="rvenutolo/linPEAS-flake"
readonly OVERRIDE="${WORKFLOWS_DIR_OVERRIDE:-}"
readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
readonly DIR="${OVERRIDE:-${DEFAULT_DIR}}"
readonly REPO_SLUG="${REPO_SLUG_OVERRIDE:-${DEFAULT_REPO_SLUG}}"
readonly GUARD_NEEDLE="github.repository == '${REPO_SLUG}'"
# The job a key names. The job list is read with `keys`, which refuses
# `jobs:` written as an alias, so no lookup meets one. The key reaches
# `yq` as data, through `strenv`, and is compared by its base64 text:
# spliced into the expression, a key holding a quote would be read as
# `yq` code, and `yq` reads `*` and `?` in an index or an `==` comparison
# as wildcards, which base64 text never holds. `explode` resolves merge
# keys and aliases first, and of keys written twice the last is read, as
# `yq`'s own lookup reads it.
readonly JOB_BY_KEY='.jobs | explode(.) | [to_entries[] | select((.key | tostring | @base64) == (strenv(JOB) | @base64))] | reverse | .[0] | .value'

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 2
fi

# @description Print one expression's value from a workflow. Returns
# non-zero, naming what it read and the job, when `yq` cannot evaluate
# it. The scan has already proved this file parses, so a failure here is
# an expression its shape does not support — nothing about the job's
# permissions was read, and an unchecked read would leave the run
# carrying yq's own exit 1, indistinguishable from a job found missing
# its fork guard. The job key reaches `yq` as `strenv(JOB)`, which the
# expression reads through JOB_BY_KEY.
# @arg $1 workflow path
# @arg $2 yq expression, finding the job through JOB_BY_KEY
# @arg $3 job key
# @arg $4 what the expression reads, for the message
# @exitcode 1 yq could not evaluate the expression against the file
function read_workflow() {
  local -r file="$1" expr="$2" job="$3" what="$4"
  local value
  if ! value="$(JOB="${job}" yq eval "${expr}" "${file}")"; then
    printf 'cannot read the %s of job %q from %s\n' "${what}" "${job}" "${file}" >&2
    return 1
  fi
  printf '%s' "${value}"
}

# Detect a guard-required write scope on one job. Returns 0 if found.
job_needs_fork_guard() {
  local -r file="$1" job="$2"
  for scope in contents packages id-token attestations actions; do
    local val
    if ! val="$(read_workflow "${file}" "${JOB_BY_KEY} | .permissions.\"${scope}\" // \"\"" "${job}" "${scope} permission")"; then
      exit 2
    fi
    if [[ ${val} == "write" ]]; then
      return 0
    fi
  done
  # App installation token = real write privilege despite a read-only
  # GITHUB_TOKEN. A job minting one must carry the fork guard.
  local body
  if ! body="$(read_workflow "${file}" "${JOB_BY_KEY}" "${job}" body)"; then
    exit 2
  fi
  [[ ${body} == *"actions/create-github-app-token"* ]] && return 0
  [[ ${body} == *"secrets.BUMP_APP_PRIVATE_KEY"* ]] && return 0
  return 1
}

failed=0
shopt -s nullglob
declare -a workflow_files=()
glob_into workflow_files 'workflow YAML' "${DIR}/*.yml" "${DIR}/*.yaml"
declare -a selected_files=()
filter_into selected_files 'workflow YAML' "${FILE_FILTER}" "${workflow_files[@]}"
for f in "${selected_files[@]}"; do
  [[ -f ${f} ]] || continue

  # The workflow's first read: `yq` prints one index per document, and
  # GitHub Actions refuses a file holding several, so such a file is a
  # finding and is read no further.
  if ! doc_indexes="$(yq eval 'document_index' "${f}")"; then
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi
  if [[ ${doc_indexes} == *$'\n'* ]]; then
    printf '%s: holds several YAML documents; a workflow file must hold one\n' "${f}" >&2
    failed=$((failed + 1))
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
    if ! if_clause="$(read_workflow "${f}" "${JOB_BY_KEY}"' | .if // ""' "${job}" 'if:')"; then
      exit 2
    fi
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
