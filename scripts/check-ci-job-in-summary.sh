#!/usr/bin/env bash
# scripts/check-ci-job-in-summary.sh
#
# @description Lint: cross-check `.github/workflows/ci.yml` jobs
# against `docs/_data/ci-check-categories.yml` in both directions,
# with a self-policed EXEMPT list for auxiliary (non-required) jobs.
# @option --print-exempt print the EXEMPT job list, one name per line, and exit 0 without linting

# Lint: cross-check `.github/workflows/ci.yml` jobs against
# `docs/_data/ci-check-categories.yml`.
#
# Forward — every `jobs.<name>:` in `ci.yml` either appears as a key
# in the category map OR is on the EXEMPT list of auxiliary jobs that
# legitimately don't show up as required status checks. EXEMPT is
# currently empty: every ci.yml job is mapped. It is self-policed —
# an entry must name a real `ci.yml` job that is absent from the
# category map, so it cannot rot into a name that exempts nothing.
#
# Reverse — every key in the category map names a real `jobs.<name>:`
# in some workflow under `.github/workflows/`. The map itself does not
# record which workflow an entry belongs to, so the check spans all of
# them: entries naming jobs in other files (gitleaks, dependency-review,
# pr-title-lint, …) are in scope and must resolve too.
#
# Manifest coverage — every check basename in
# `.github/lint-groups.yml` resolves to a real
# `scripts/check-<basename>.sh`. The grouped lint jobs no longer name
# each check individually in `ci.yml`, so without this a check could
# silently leave the merge gate (manifest entry orphaned, or the
# script deleted) after its job was folded into a group.
#
# Adding a new ci.yml job that should be a required status check:
#   - add the job to ci.yml
#   - add an entry to docs/_data/ci-check-categories.yml
#   - add an entry to docs/security/required-checks.md
#   - update .github/rulesets/protect-main.json
#   - sync the live ruleset
# Adding a new auxiliary ci.yml job (test sandbox, notify-style):
#   - add the job to ci.yml
#   - add the job name to the EXEMPT list in this script; it must be a
#     real ci.yml job with no category-map key, or the lint rejects it
#
# See docs/security/workflow-hardening.md.
#
# EXEMPT as a shared list — `--print-exempt` writes the list to stdout,
# one name per line, and exits 0 without touching ci.yml or the category
# map. An empty list prints nothing, so exit status carries "the list is
# empty" and only a nonzero exit means "the list is unreadable".
# scripts/refresh-enforcement-matrix.sh reads its ci-job exemptions from
# this mode, so one declaration serves both lints instead of one script
# re-deriving the other's source. Any other argument exits 2, so a
# renamed or dropped mode fails loud in the caller.
#
# Honors CI_WORKFLOW_OVERRIDE + CATEGORIES_FILE_OVERRIDE +
# LINT_GROUPS_OVERRIDE + SCRIPTS_DIR_OVERRIDE + EXEMPT_OVERRIDE for
# fixtures. Exits 0 on full coverage, 1 on any drift, 2 when the lint
# could not run: a usage error, a missing tool, or an input file
# (ci.yml, the category map, the lint-groups manifest) missing or
# unparsable. Nothing was cross-checked in that case, so it must not
# borrow the drift code.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"

readonly DEFAULT_CI=".github/workflows/ci.yml"
readonly DEFAULT_CATEGORIES="docs/_data/ci-check-categories.yml"
readonly DEFAULT_WORKFLOWS_DIR=".github/workflows"
readonly DEFAULT_LINT_GROUPS=".github/lint-groups.yml"
readonly DEFAULT_SCRIPTS_DIR="scripts"
readonly CI_FILE="${CI_WORKFLOW_OVERRIDE:-${DEFAULT_CI}}"
readonly CATEGORIES_FILE="${CATEGORIES_FILE_OVERRIDE:-${DEFAULT_CATEGORIES}}"
readonly WORKFLOWS_DIR="${WORKFLOWS_DIR_OVERRIDE:-${DEFAULT_WORKFLOWS_DIR}}"
readonly LINT_GROUPS_FILE="${LINT_GROUPS_OVERRIDE:-${DEFAULT_LINT_GROUPS}}"
readonly SCRIPTS_DIR="${SCRIPTS_DIR_OVERRIDE:-${DEFAULT_SCRIPTS_DIR}}"

# ci.yml jobs deliberately not exposed as required status checks.
# Currently empty: every ci.yml job is mapped in the category file.
# Self-policed below — an entry must name a real ci.yml job that is
# absent from the category map, so the list cannot rot into a set of
# names that exempt nothing while the lint stays green.
EXEMPT=()
if [[ -n ${EXEMPT_OVERRIDE:-} ]]; then
  while IFS= read -r e; do
    [[ -z ${e} ]] && continue
    EXEMPT+=("${e}")
  done <<<"${EXEMPT_OVERRIDE}"
fi
readonly EXEMPT

# Argument handling runs after EXEMPT is assembled so `--print-exempt`
# reflects EXEMPT_OVERRIDE, and before the tool/file preamble so the mode
# stays readable without yq or a checked-out ci.yml.
if (($# > 0)); then
  case "$1" in
  --print-exempt)
    if (($# > 1)); then
      printf 'unexpected extra arguments after %s\n' "$1" >&2
      exit 2
    fi
    if ((${#EXEMPT[@]} > 0)); then
      printf '%s\n' "${EXEMPT[@]}"
    fi
    exit 0
    ;;
  *)
    printf 'unknown argument: %s\n' "$1" >&2
    exit 2
    ;;
  esac
fi

is_exempt() {
  local -r name="$1"
  local e
  for e in ${EXEMPT[@]+"${EXEMPT[@]}"}; do
    [[ ${name} == "${e}" ]] && return 0
  done
  return 1
}

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 2
fi
if [[ ! -f ${CI_FILE} ]]; then
  printf 'ci workflow not found: %s\n' "${CI_FILE}" >&2
  exit 2
fi
if [[ ! -f ${CATEGORIES_FILE} ]]; then
  printf 'categories file not found: %s\n' "${CATEGORIES_FILE}" >&2
  exit 2
fi

ci_jobs_file="$(make_temp)"
cat_keys_file="$(make_temp)"
trap 'rm --force -- "${ci_jobs_file}" "${cat_keys_file}"' EXIT

yq eval '.jobs | keys | .[]' "${CI_FILE}" | sort --unique >"${ci_jobs_file}"
yq eval 'keys | .[]' "${CATEGORIES_FILE}" | sort --unique >"${cat_keys_file}"

failed=0

# Forward: ci.yml job not in categories AND not exempt = fail.
while IFS= read -r job; do
  [[ -z ${job} ]] && continue
  if grep --quiet --fixed-strings --line-regexp -- "${job}" "${cat_keys_file}"; then
    continue
  fi
  if is_exempt "${job}"; then
    continue
  fi
  printf '%s: job %q is not in %s and not on the EXEMPT list\n' \
    "${CI_FILE}" "${job}" "${CATEGORIES_FILE}" >&2
  failed=$((failed + 1))
done <"${ci_jobs_file}"

# EXEMPT self-policing. Both shapes below leave the list syntactically
# valid while covering no job, so the lint would stay green with an
# exemption that exempts nothing.
for e in ${EXEMPT[@]+"${EXEMPT[@]}"}; do
  if ! grep --quiet --fixed-strings --line-regexp -- "${e}" "${ci_jobs_file}"; then
    printf 'EXEMPT entry %q is not a job in %s\n' "${e}" "${CI_FILE}" >&2
    failed=$((failed + 1))
    continue
  fi
  if grep --quiet --fixed-strings --line-regexp -- "${e}" "${cat_keys_file}"; then
    printf 'EXEMPT entry %q is already a key in %s\n' \
      "${e}" "${CATEGORIES_FILE}" >&2
    failed=$((failed + 1))
  fi
done

# Reverse: a category entry that targets a ci.yml job must exist.
# We can't tell from categories.yml alone which entries point at
# ci.yml vs other workflows, so the reverse check is: any entry that
# is NOT a job in some workflow file is a drift signal. Build the
# full job set across all workflows once.
all_jobs_file="$(make_temp)"
trap 'rm --force -- "${ci_jobs_file}" "${cat_keys_file}" "${all_jobs_file}"' EXIT
shopt -s nullglob
# Enumerated before the pipeline rather than inside it: a glob expanded in
# the `for` head runs in the pipeline's own subshell, where an exit would
# end that subshell alone and leave the redirect writing an empty job set.
declare -a workflow_files=()
glob_into workflow_files 'workflow YAML' "${WORKFLOWS_DIR}/*.yml" "${WORKFLOWS_DIR}/*.yaml"
for f in "${workflow_files[@]}"; do
  [[ -f ${f} ]] || continue
  yq eval '.jobs // {} | keys | .[]' "${f}" 2>/dev/null || true
done | sort --unique >"${all_jobs_file}"
shopt -u nullglob

while IFS= read -r key; do
  [[ -z ${key} ]] && continue
  if ! grep --quiet --fixed-strings --line-regexp -- "${key}" "${all_jobs_file}"; then
    printf '%s: category entry %q does not match any job in .github/workflows/\n' \
      "${CATEGORIES_FILE}" "${key}" >&2
    failed=$((failed + 1))
  fi
done <"${cat_keys_file}"

# Manifest coverage: every check basename in lint-groups.yml must
# resolve to a real scripts/check-<basename>.sh. Guards against a check
# silently dropping off the merge gate once its job is folded into a
# grouped lint job.
# A missing manifest is a load-bearing infrastructure error, not drift —
# it carries the could-not-run code, like the CI_FILE / CATEGORIES_FILE
# preamble guards above.
if [[ ! -f ${LINT_GROUPS_FILE} ]]; then
  printf 'lint-groups manifest not found: %s\n' "${LINT_GROUPS_FILE}" >&2
  exit 2
fi

# Capture yq's output (and exit status) into a variable rather than
# feeding the loop from `< <(yq ...)`: a process substitution's exit
# status is not propagated under set -Eeuo pipefail, so a yq failure
# would yield empty input and manifest coverage would pass silently. The
# manifest is a precondition file, not a scanned artifact, so an
# unparsable manifest is a tooling error (exit 2) like the missing-file
# guard above.
if ! basenames_rows="$(yq eval '.[] | .[]' "${LINT_GROUPS_FILE}")"; then
  printf '%s: could not evaluate lint-groups manifest with yq (malformed?)\n' "${LINT_GROUPS_FILE}" >&2
  exit 2
fi
while IFS= read -r basename; do
  [[ -z ${basename} ]] && continue
  script="${SCRIPTS_DIR}/check-${basename}.sh"
  if [[ ! -f ${script} ]]; then
    printf '%s: lint-groups basename %q has no check script (%s)\n' \
      "${LINT_GROUPS_FILE}" "${basename}" "${script}" >&2
    failed=$((failed + 1))
  fi
done <<<"${basenames_rows}"

if ((failed > 0)); then
  printf '%d ci.yml / categories drift entry/entries\n' "${failed}" >&2
  exit 1
fi
exit 0
