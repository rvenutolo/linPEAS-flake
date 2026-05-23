#!/usr/bin/env bash
# scripts/check-fork-guard-release.sh
#
# Lint: every workflow job that holds release-grade GITHUB_TOKEN
# scope includes a fork-guard `if:` clause containing
# `github.repository == 'rvenutolo/linPEAS-flake'`.
#
# Release-grade scopes (any of):
#   - contents: write       — push commits / tags / releases
#   - packages: write       — push container images / packages
#   - id-token: write       — mint OIDC tokens (cosign signing)
#   - attestations: write   — record SLSA attestations
#
# Without the guard, a fork that inherits these workflows can fire
# them under its own GITHUB_TOKEN (or repo-scoped secrets, if any
# were configured). The repository check pins execution to the
# canonical repo.
#
# A workflow-level guard isn't valid in GitHub Actions syntax (`if:`
# is job-scoped), so every release-grade job must carry the guard
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

# Detect release-grade scope on one job. Returns 0 if release-grade.
job_is_release_grade() {
  local -r file="$1" job="$2"
  for scope in contents packages id-token attestations; do
    local val
    val="$(yq eval ".jobs.\"${job}\".permissions.\"${scope}\" // \"\"" "${file}")"
    if [[ ${val} == "write" ]]; then
      return 0
    fi
  done
  return 1
}

failed=0
shopt -s nullglob
for f in "${DIR}"/*.yml "${DIR}"/*.yaml; do
  [[ -f ${f} ]] || continue
  if [[ -n ${FILE_FILTER} && "$(basename "${f}")" != "${FILE_FILTER}" ]]; then
    continue
  fi

  while IFS= read -r job; do
    [[ -z ${job} ]] && continue
    if ! job_is_release_grade "${f}" "${job}"; then
      continue
    fi
    if_clause="$(yq eval ".jobs.\"${job}\".if // \"\"" "${f}")"
    if [[ ${if_clause} != *"${GUARD_NEEDLE}"* ]]; then
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      printf '%s: job %q holds release-grade scope but is missing fork guard `%s`; got if=%q\n' \
        "${f}" "${job}" "${GUARD_NEEDLE}" "${if_clause}" >&2
      failed=$((failed + 1))
    fi
  done < <(yq eval '.jobs // {} | keys | .[]' "${f}")
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d release-grade job(s) missing fork guard\n' "${failed}" >&2
  exit 1
fi
exit 0
