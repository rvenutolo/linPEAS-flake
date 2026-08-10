#!/usr/bin/env bash
# scripts/check-min-permissions.sh
#
# @description Strict least-privilege lint for GitHub Actions
# GITHUB_TOKEN scopes: top-level `permissions: {}` and an explicit
# per-job `permissions:` block in every workflow.

# Strict least-privilege lint for GitHub Actions GITHUB_TOKEN scopes.
# Asserts, for every .github/workflows/*.yml:
#
#   1. Top-level `permissions:` is the empty map `{}`. No scopes
#      granted at workflow scope — every scope must be explicit per-job.
#   2. Every job declares its own `permissions:` block. Inheritance
#      from top-level (which is empty anyway) is not allowed; an
#      omitted block is a lint failure.
#   3. Top-level cannot be `read-all`, `write-all`, or any scalar/
#      list form. (Subsumed by rule 1 but reported with a clearer
#      message when the input shape is one of those.)
#
# See docs/security/min-permissions.md.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER for fixtures.
# Exits 0 on full coverage, 1 on any drift.

set -Eeuo pipefail
IFS=$'\n\t'

readonly DEFAULT_DIR=".github/workflows"
readonly OVERRIDE="${WORKFLOWS_DIR_OVERRIDE:-}"
readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
readonly DIR="${OVERRIDE:-${DEFAULT_DIR}}"

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 2
fi

failed=0
shopt -s nullglob
for f in "${DIR}"/*.yml "${DIR}"/*.yaml; do
  [[ -f ${f} ]] || continue
  if [[ -n ${FILE_FILTER} && "$(basename "${f}")" != "${FILE_FILTER}" ]]; then
    continue
  fi

  # --- top-level permissions ---------------------------------------
  top_tag="$(yq eval '.permissions | tag' "${f}")"
  case "${top_tag}" in
  '!!null')
    # shellcheck disable=SC2016 # literal backticks in human-readable prose
    printf '%s: missing top-level `permissions:` (need `permissions: {}`)\n' "${f}" >&2
    failed=$((failed + 1))
    ;;
  '!!str')
    top_val="$(yq eval '.permissions' "${f}")"
    # shellcheck disable=SC2016 # literal backticks in human-readable prose
    printf '%s: top-level permissions is scalar %q (need `permissions: {}`)\n' \
      "${f}" "${top_val}" >&2
    failed=$((failed + 1))
    ;;
  '!!map')
    top_len="$(yq eval '.permissions | length' "${f}")"
    if [[ ${top_len} != "0" ]]; then
      top_keys="$(yq eval '.permissions | keys | join(",")' "${f}")"
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      printf '%s: top-level permissions non-empty (keys: %s); need `permissions: {}`\n' \
        "${f}" "${top_keys}" >&2
      failed=$((failed + 1))
    fi
    ;;
  *)
    printf '%s: top-level permissions has unexpected shape (tag=%s)\n' \
      "${f}" "${top_tag}" >&2
    failed=$((failed + 1))
    ;;
  esac

  # --- per-job permissions -----------------------------------------
  # Capture yq's output (and exit status) into a variable rather than
  # feeding the loop from `< <(yq ...)`: a process substitution's exit
  # status is not propagated under set -Eeuo pipefail, so a yq failure
  # (e.g. `jobs:` is not a map) would yield empty input and the per-job
  # scan would pass silently.
  if ! rows="$(yq eval '.jobs | to_entries[] | .key + "\t" + (.value.permissions | tag)' "${f}")"; then
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi
  [[ -n ${rows} ]] || continue
  while IFS=$'\t' read -r job job_tag; do
    [[ -z ${job} ]] && continue
    case "${job_tag}" in
    '!!null')
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      printf '%s: job %q missing `permissions:` block (every job must declare its own)\n' \
        "${f}" "${job}" >&2
      failed=$((failed + 1))
      ;;
    '!!map')
      : # ok; scope-level audit out of scope for this lint
      ;;
    *)
      printf '%s: job %q permissions has unexpected shape (tag=%s)\n' \
        "${f}" "${job}" "${job_tag}" >&2
      failed=$((failed + 1))
      ;;
    esac
  done <<<"${rows}"
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d permissions posture violation(s) found\n' "${failed}" >&2
  exit 1
fi
exit 0
