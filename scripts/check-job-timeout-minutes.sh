#!/usr/bin/env bash
# scripts/check-job-timeout-minutes.sh
#
# Lint: every job under .github/workflows/*.yml declares
# `timeout-minutes`. The default GitHub Actions job timeout is 6 hours,
# which lets a hung job burn the runner budget and stall the merge
# queue. Requiring an explicit per-job value bounds blast radius.
#
# A job satisfies the lint when `.jobs.<name>.timeout-minutes` is an
# integer scalar. Reusable-workflow jobs (those calling another
# workflow via `uses:`) are exempt because `timeout-minutes` is not
# valid on that shape.
#
# See docs/security/workflow-hardening.md.
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

  while IFS='|' read -r job uses_tag timeout_tag timeout_val; do
    [[ -z ${job} ]] && continue

    # Reusable-workflow jobs (uses: <ref>) don't accept timeout-minutes.
    if [[ ${uses_tag} == "!!str" ]]; then
      continue
    fi

    case "${timeout_tag}" in
    '!!null')
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      printf '%s: job %q missing `timeout-minutes` (default is 6h; declare an explicit value)\n' \
        "${f}" "${job}" >&2
      failed=$((failed + 1))
      ;;
    '!!int')
      if [[ ${timeout_val} -le 0 ]]; then
        printf '%s: job %q timeout-minutes must be positive (got %s)\n' \
          "${f}" "${job}" "${timeout_val}" >&2
        failed=$((failed + 1))
      fi
      ;;
    *)
      printf '%s: job %q timeout-minutes has unexpected shape (tag=%s, value=%s); expected integer\n' \
        "${f}" "${job}" "${timeout_tag}" "${timeout_val}" >&2
      failed=$((failed + 1))
      ;;
    esac
  done < <(yq eval '.jobs | to_entries[] | .key + "|" + (.value.uses | tag) + "|" + (.value."timeout-minutes" | tag) + "|" + (.value."timeout-minutes" | tostring)' "${f}")
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d job(s) missing or invalid timeout-minutes\n' "${failed}" >&2
  exit 1
fi
exit 0
