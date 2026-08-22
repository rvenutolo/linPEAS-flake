#!/usr/bin/env bash
# scripts/docs-audit-pressure.sh
#
# @description Report docs-audit drift pressure since the last audit:
# how many commits touched CI structure (.github/workflows, scripts,
# .github/lint-groups.yml), and which job ids / lint-group members were
# added or removed. Emits a Markdown body for the monthly docs-audit
# reminder issue, terminated by a machine-readable PRESSURE=<n> line.
#
# Freshness gates validate only generated blocks; hand-written prose about
# CI drifts silently. CI churn is the best cheap proxy for that drift, so it
# decides whether a semantic audit is worth running this month.
#
# The diff base is the commit recorded in `.github/docs-audit-state`, which
# `scripts/mark-docs-audit.sh` writes once an audit's fixes have landed. A
# fixed-length window would measure churn the maintainer has already read
# and audited, so its count could never fall to zero on a repo with a
# steady commit rate — and the reminder issue's close condition reads that
# count. Measuring from the audit point makes the number mean "CI-structure
# commits nobody has audited yet", which is zero right after an audit and
# grows only with unreviewed churn.
#
# Body contents are restricted to integers and shape-validated identifiers
# parsed from YAML — never commit subjects or other free text, which would
# render as arbitrary markdown in the resulting issue.
#
# Honors LINT_ALLOW_EMPTY_SCAN=1 to accept a ref whose workflows dir holds
# no YAML.
#
# Exit codes:
#   0  success (body on stdout, PRESSURE=<n> as the final line)
#   2  missing inputs / parse error / nothing enumerated to measure,
#      including an audit-state file that is absent, carries no
#      LAST_AUDIT_SHA=<40-hex> line, or names a commit this history does
#      not contain

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"

readonly AUDIT_STATE="${DOCS_AUDIT_STATE_OVERRIDE:-.github/docs-audit-state}"
readonly WORKFLOWS_DIR="${WORKFLOWS_DIR_OVERRIDE:-.github/workflows}"
readonly LINT_GROUPS="${LINT_GROUPS_OVERRIDE:-.github/lint-groups.yml}"

# A job id we are willing to render into markdown.
readonly JOB_ID_RE='^[a-z0-9][a-z0-9-]*$'

# @description Print the commit recorded as the last audit point. Every
#              could-not-run shape exits 2 rather than falling back to a
#              window or to the repo's first commit: a fallback base still
#              prints a PRESSURE line, and the reminder workflow would
#              file that number as though it had been measured from the
#              audit point it names.
function last_audit_ref() {
  local -r state="${AUDIT_STATE}"
  if [[ ! -r ${state} ]]; then
    printf 'cannot read audit-state file: %s\n' "${state}" >&2
    # shellcheck disable=SC2016 # literal backticks in human-readable prose
    printf 'run `just docs-audit-done` once an audit has landed\n' >&2
    exit 2
  fi

  local sha
  sha="$(sed -n 's/^LAST_AUDIT_SHA=//p' "${state}" | head -n 1)"
  if [[ ! ${sha} =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s: no LAST_AUDIT_SHA=<40-hex> line\n' "${state}" >&2
    exit 2
  fi

  # A sha that parses but names no commit here — a rewritten history, or a
  # shallow clone — is an input read and found unusable, not a verdict
  # about the repo's prose.
  if ! git rev-parse --quiet --verify "${sha}^{commit}" >/dev/null 2>&1; then
    printf '%s: LAST_AUDIT_SHA %s is not a commit in this history\n' \
      "${state}" "${sha}" >&2
    exit 2
  fi

  printf '%s\n' "${sha}"
}

# @description Emit sorted job ids present at a given ref. Only ids matching
#              JOB_ID_RE are emitted; the rest are counted by the caller.
# @arg $1 git ref
function job_ids_at() {
  local -r ref="$1"
  local path
  # An enumeration that comes back empty — failed, or pointed at a path the
  # ref never tracked — produces an empty id set, which the diff below
  # renders as "no jobs added, no jobs removed" and the summary reports as
  # zero drift pressure. A metric that says zero because it measured
  # nothing is the one reading this function must not emit; the raw
  # enumeration asserts that itself via enumerate_into before the
  # YAML-extension filter below asserts it again on the filtered set.
  local -a tree_paths=()
  enumerate_into tree_paths "git ls-tree ${WORKFLOWS_DIR} at ${ref}" \
    git ls-tree --name-only -z -r "${ref}" -- "${WORKFLOWS_DIR}"
  local -a workflow_paths=()
  for path in "${tree_paths[@]}"; do
    [[ ${path} =~ \.ya?ml$ ]] || continue
    workflow_paths+=("${path}")
  done
  if ((${#workflow_paths[@]} == 0)) && [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
    printf 'enumerated 0 workflow file(s) under %s at %s; set LINT_ALLOW_EMPTY_SCAN=1 if that ref is deliberately empty\n' \
      "${WORKFLOWS_DIR}" "${ref}" >&2
    return 2
  fi
  for path in ${workflow_paths+"${workflow_paths[@]}"}; do
    git show "${ref}:${path}" 2>/dev/null |
      yq --exit-status '.jobs | keys | .[]' - 2>/dev/null || true
  done | tr -d '"' | sort -u
}

# @description Print a path relative to the repo root. `git show ref:path`
#              (blob syntax, unlike pathspecs) rejects absolute paths, so
#              overrides passed as absolute paths must be rebased first.
# @arg $1 path, absolute or already relative
function repo_relative() {
  local -r path="$1"
  local root
  root="$(git rev-parse --show-toplevel)"
  if [[ ${path} == "${root}"/* ]]; then
    printf '%s\n' "${path#"${root}"/}"
  else
    printf '%s\n' "${path}"
  fi
}

# @description Emit sorted lint-group member names at a given ref.
# @arg $1 git ref
function members_at() {
  local -r ref="$1"
  local -r lint_groups_rel="$(repo_relative "${LINT_GROUPS}")"
  git show "${ref}:${lint_groups_rel}" 2>/dev/null |
    yq --exit-status '.[] | .[]' - 2>/dev/null |
    tr -d '"' | sort -u || true
}

# @description Filter stdin to ids safe to render; drop the rest.
function only_valid_ids() {
  grep -E "${JOB_ID_RE}" || true
}

# @description Render a labeled Markdown list from newline-separated ids,
#              one `- \`id\`` line per entry. Emits nothing for an empty
#              list. Reads ids via a loop (not unquoted word-splitting) so
#              ids are never subject to glob expansion or field splitting.
# @arg $1 label
# @arg $2 newline-separated ids
function render_list() {
  local -r label="$1"
  local -r list="$2"
  [[ -n ${list} ]] || return 0

  printf '%s:\n' "${label}"
  local id
  while IFS= read -r id; do
    [[ -n ${id} ]] || continue
    # shellcheck disable=SC2016 # literal backticks in human-readable prose
    printf -- '- `%s`\n' "${id}"
  done <<<"${list}"
  printf '\n'
}

function main() {
  [[ -d ${WORKFLOWS_DIR} ]] || {
    printf 'missing workflows dir: %s\n' "${WORKFLOWS_DIR}" >&2
    exit 2
  }

  # `last_audit_ref` exits 2 from inside the substitution on every
  # could-not-run shape, which propagates through this assignment.
  local base
  base="$(last_audit_ref)"

  local commits
  commits="$(
    git log --oneline "${base}..HEAD" \
      -- "${WORKFLOWS_DIR}" scripts "${LINT_GROUPS}" 2>/dev/null | wc -l | tr -d ' '
  )"

  # The two id sets are resolved into variables before they are compared:
  # a `job_ids_at` failure inside `comm <(…)` would exit its own subshell
  # and leave `comm` diffing an empty set at exit 0, which is the fail-open
  # the function's own status check exists to prevent.
  local base_jobs head_jobs
  base_jobs="$(job_ids_at "${base}")" || exit 2
  head_jobs="$(job_ids_at HEAD)" || exit 2

  local jobs_added jobs_removed members_added members_removed
  jobs_added="$(comm -13 <(printf '%s\n' "${base_jobs}") <(printf '%s\n' "${head_jobs}") | only_valid_ids)"
  jobs_removed="$(comm -23 <(printf '%s\n' "${base_jobs}") <(printf '%s\n' "${head_jobs}") | only_valid_ids)"
  members_added="$(comm -13 <(members_at "${base}") <(members_at HEAD) | only_valid_ids)"
  members_removed="$(comm -23 <(members_at "${base}") <(members_at HEAD) | only_valid_ids)"

  printf 'Drift pressure since the last audit: **%s** commit(s) touching CI structure.\n\n' \
    "${commits}"

  render_list 'Jobs added' "${jobs_added}"
  render_list 'Jobs removed' "${jobs_removed}"
  render_list 'Lint-group members added' "${members_added}"
  render_list 'Lint-group members removed' "${members_removed}"

  printf 'Hand-written prose about CI is not covered by any freshness gate.\n'
  # shellcheck disable=SC2016 # literal backticks in human-readable prose
  printf 'Run `/docs-audit` and fix what it finds.\n\n'
  printf 'PRESSURE=%s\n' "${commits}"
}

main "$@"
