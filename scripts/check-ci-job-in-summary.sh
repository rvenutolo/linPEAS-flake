#!/usr/bin/env bash
# scripts/check-ci-job-in-summary.sh
#
# @description Lint: cross-check `.github/workflows/ci.yml` jobs
# against `docs/_data/ci-check-categories.yml` in both directions,
# with an EXEMPT list for auxiliary (non-required) jobs.

# Lint: cross-check `.github/workflows/ci.yml` jobs against
# `docs/_data/ci-check-categories.yml`.
#
# Forward — every `jobs.<name>:` in `ci.yml` either appears as a key
# in the category map OR is on the EXEMPT list of auxiliary jobs that
# legitimately don't show up as required status checks (sandbox /
# notify / matrix-expansion jobs).
#
# Reverse — every key in `ci.yml`'s share of the category map
# corresponds to a real `jobs.<name>:` in `ci.yml`. Category-map
# entries that point at jobs in other workflow files (gitleaks,
# dependency-review, pr-title-lint, …) are not the responsibility
# of this lint.
#
# Adding a new ci.yml job that should be a required status check:
#   - add the job to ci.yml
#   - add an entry to docs/_data/ci-check-categories.yml
#   - add an entry to docs/security/required-checks.md
#   - update .github/rulesets/protect-main.json
#   - sync the live ruleset
# Adding a new auxiliary ci.yml job (test sandbox, notify-style):
#   - add the job to ci.yml
#   - add the job name to the EXEMPT list in this script
#
# See docs/security/workflow-hardening.md.
#
# Honors CI_WORKFLOW_OVERRIDE + CATEGORIES_FILE_OVERRIDE for fixtures.
# Exits 0 on full coverage, 1 on any drift.

set -Eeuo pipefail
IFS=$'\n\t'

readonly DEFAULT_CI=".github/workflows/ci.yml"
readonly DEFAULT_CATEGORIES="docs/_data/ci-check-categories.yml"
readonly DEFAULT_WORKFLOWS_DIR=".github/workflows"
readonly CI_FILE="${CI_WORKFLOW_OVERRIDE:-${DEFAULT_CI}}"
readonly CATEGORIES_FILE="${CATEGORIES_FILE_OVERRIDE:-${DEFAULT_CATEGORIES}}"
readonly WORKFLOWS_DIR="${WORKFLOWS_DIR_OVERRIDE:-${DEFAULT_WORKFLOWS_DIR}}"

# Auxiliary ci.yml jobs intentionally absent from the category map.
# Each entry is a job not exposed as a required status check.
readonly EXEMPT=(
  "allowed-actions-api-harness"     # harness sandbox
  "build-linpeas-matrix"            # cross-OS matrix expansion
  "flake-check-matrix"              # cross-OS matrix expansion
  "gh-api-version-header"           # harness sandbox
  "image-cve-scan"                  # CVE scan; surfaces issues, not blocker
  "image-cve-scan-notify-finding"   # notify-only job (real CRITICAL CVE)
  "image-cve-scan-notify-infra"     # notify-only job (infra failure, no CVE)
  "refresh-ci-summary-test"         # regenerator harness
  "refresh-enforcement-matrix-test" # regenerator harness
  "refresh-just-recipes-test"       # regenerator harness
  "refresh-precommit-table-test"    # regenerator harness
  "refresh-scripts-reference-test"  # regenerator harness
  "settings-posture-harness"        # harness sandbox
)

is_exempt() {
  local -r name="$1"
  local e
  for e in "${EXEMPT[@]}"; do
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
  exit 1
fi
if [[ ! -f ${CATEGORIES_FILE} ]]; then
  printf 'categories file not found: %s\n' "${CATEGORIES_FILE}" >&2
  exit 1
fi

ci_jobs_file="$(mktemp)"
cat_keys_file="$(mktemp)"
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

# Reverse: a category entry that targets a ci.yml job must exist.
# We can't tell from categories.yml alone which entries point at
# ci.yml vs other workflows, so the reverse check is: any entry that
# is NOT a job in some workflow file is a drift signal. Build the
# full job set across all workflows once.
all_jobs_file="$(mktemp)"
trap 'rm --force -- "${ci_jobs_file}" "${cat_keys_file}" "${all_jobs_file}"' EXIT
shopt -s nullglob
for f in "${WORKFLOWS_DIR}"/*.yml "${WORKFLOWS_DIR}"/*.yaml; do
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

if ((failed > 0)); then
  printf '%d ci.yml / categories drift entry/entries\n' "${failed}" >&2
  exit 1
fi
exit 0
