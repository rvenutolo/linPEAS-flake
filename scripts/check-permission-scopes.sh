#!/usr/bin/env bash
# scripts/check-permission-scopes.sh
#
# @description Per-job GITHUB_TOKEN write-scope allowlist lint for
# GitHub Actions. Fails when a job grants a write scope absent from
# .github/permission-scopes.yml, or when an allowlist entry is stale.

# Hand-maintained allowlist gate. .github/permission-scopes.yml is the
# source of truth for which *write* scopes each job may hold. For every
# .github/workflows/*.yml job this asserts:
#
#   1. Every scope the job grants with value `write` is listed under that
#      job in the allowlist. An un-listed write scope is an over-grant.
#   2. Every scope listed for the job in the allowlist is actually granted
#      `write` by the job, and every allowlist workflow/job exists. A
#      listed-but-absent scope (or a vanished workflow/job) is stale.
#
# Read and `none` scope values are ignored — least-privilege concern is
# write over-grant. See docs/security/min-permissions.md.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER + SCOPE_ALLOWLIST_OVERRIDE
# for fixtures. Exit 0 clean, 1 on drift, 2 on config/tooling error.

# $k/$wf/$job in the yq expressions below are yq variables, not shell.
# shellcheck disable=SC2016
set -Eeuo pipefail
IFS=$'\n\t'

readonly DEFAULT_DIR=".github/workflows"
readonly DEFAULT_ALLOWLIST=".github/permission-scopes.yml"
readonly DIR="${WORKFLOWS_DIR_OVERRIDE:-${DEFAULT_DIR}}"
readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
readonly ALLOWLIST="${SCOPE_ALLOWLIST_OVERRIDE:-${DEFAULT_ALLOWLIST}}"

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 2
fi
if [[ ! -f ${ALLOWLIST} ]]; then
  printf 'allowlist file not found: %s\n' "${ALLOWLIST}" >&2
  exit 2
fi

# allowed <workflow-basename> <job> -> newline-separated allowed scope names
function allowed() {
  yq eval ".\"$1\".\"$2\" // [] | .[]" "${ALLOWLIST}"
}

failed=0
shopt -s nullglob

# --- forward: workflow write scopes ⊆ allowlist -------------------------
for f in "${DIR}"/*.yml "${DIR}"/*.yaml; do
  [[ -f ${f} ]] || continue
  base="$(basename "${f}")"
  if [[ -n ${FILE_FILTER} && ${base} != "${FILE_FILTER}" ]]; then
    continue
  fi
  while IFS=$'\t' read -r job scope; do
    [[ -z ${scope} ]] && continue
    if ! grep -qxF "${scope}" <<<"$(allowed "${base}" "${job}")"; then
      printf '%s: job %q grants write scope %q not allowed by %s\n' \
        "${f}" "${job}" "${scope}" "${ALLOWLIST}" >&2
      failed=$((failed + 1))
    fi
  done < <(yq eval '.jobs | to_entries[] | .key as $k | (.value.permissions // {} | to_entries[] | select(.value == "write") | $k + "\t" + .key)' "${f}")
done

# --- reverse: allowlist entries are not stale ---------------------------
# Skip when filtered to a single fixture (the allowlist names other fixtures).
if [[ -z ${FILE_FILTER} ]]; then
  while IFS=$'\t' read -r wf job scope; do
    [[ -z ${scope} ]] && continue
    wf_path="${DIR}/${wf}"
    granted=""
    if [[ -f ${wf_path} ]]; then
      granted="$(yq eval ".jobs.\"${job}\".permissions.\"${scope}\" // \"\"" "${wf_path}")"
    fi
    if [[ ${granted} != "write" ]]; then
      printf '%s: stale entry %q/%q/%q (job does not grant that write scope)\n' \
        "${ALLOWLIST}" "${wf}" "${job}" "${scope}" >&2
      failed=$((failed + 1))
    fi
  done < <(yq eval 'to_entries[] | .key as $wf | (.value | to_entries[] | .key as $job | (.value[] | $wf + "\t" + $job + "\t" + .))' "${ALLOWLIST}")
fi

shopt -u nullglob

if ((failed > 0)); then
  printf '%d permission-scope violation(s) found\n' "${failed}" >&2
  exit 1
fi
exit 0
