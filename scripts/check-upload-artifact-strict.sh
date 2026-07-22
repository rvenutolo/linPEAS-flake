#!/usr/bin/env bash
# scripts/check-upload-artifact-strict.sh
#
# @description Lint: every `actions/upload-artifact` step in every
# workflow under `.github/workflows/*.yml` sets
# `with.if-no-files-found: error` so empty-glob bugs hard-fail.

# Lint: every `actions/upload-artifact` step in every workflow under
# `.github/workflows/*.yml` sets `with.if-no-files-found: error`.
#
# The action's default is `warn`, which silently uploads an empty
# artifact when the source path doesn't match anything. That hides
# build-output drift — a broken `path:` glob produces a green job
# with no artifact, and the consumer side notices only when something
# downstream goes missing. `error` turns the mismatch into a hard
# failure at upload time, surfacing the bug.
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

  # shellcheck disable=SC2016 # yq expression: literal $ refs, not shell expansion
  if ! rows="$(yq eval '
    .jobs | to_entries[] as $j
    | $j.value.steps | to_entries[]
    | select(.value.uses // "" | test("^actions/upload-artifact@"))
    | $j.key + "|" + (.key | tostring) + "|" + (.value.with."if-no-files-found" | tag) + "|" + (.value.with."if-no-files-found" | tostring)
  ' "${f}")"; then
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi
  while IFS='|' read -r job idx tag val; do
    [[ -z ${job} ]] && continue
    case "${tag}" in
    '!!null')
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      printf '%s: job %q step[%s] actions/upload-artifact missing `with.if-no-files-found: error`\n' \
        "${f}" "${job}" "${idx}" >&2
      failed=$((failed + 1))
      ;;
    '!!str')
      if [[ ${val} != "error" ]]; then
        # shellcheck disable=SC2016 # literal backticks in human-readable prose
        printf '%s: job %q step[%s] actions/upload-artifact has `if-no-files-found: %q`; must be `error`\n' \
          "${f}" "${job}" "${idx}" "${val}" >&2
        failed=$((failed + 1))
      fi
      ;;
    *)
      printf '%s: job %q step[%s] actions/upload-artifact if-no-files-found has unexpected shape (tag=%s, value=%s); must be string "error"\n' \
        "${f}" "${job}" "${idx}" "${tag}" "${val}" >&2
      failed=$((failed + 1))
      ;;
    esac
  done <<<"${rows}"
done
shopt -u nullglob

if ((failed > 0)); then
  # shellcheck disable=SC2016 # literal backticks in human-readable prose
  printf '%d actions/upload-artifact step(s) missing strict `if-no-files-found: error`\n' "${failed}" >&2
  exit 1
fi
exit 0
