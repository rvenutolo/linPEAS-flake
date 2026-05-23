#!/usr/bin/env bash
# scripts/check-workflow-concurrency.sh
#
# Lint: every workflow under .github/workflows/*.yml declares a
# top-level `concurrency:` block with a non-empty `group:`. Without
# one, cron pile-ups and PR/push overlap can multiply runner cost
# and let an in-flight run race a fresh push on the same ref.
#
# A workflow satisfies the lint when:
#   - `.concurrency` is a map
#   - `.concurrency.group` is a non-empty string
#
# `cancel-in-progress` is not required by this lint; the group alone
# is the load-bearing setting. Some pipelines (release-on-bump) keep
# `cancel-in-progress: false` deliberately to serialize.
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

  conc_tag="$(yq eval '.concurrency | tag' "${f}")"
  case "${conc_tag}" in
  '!!null')
    # shellcheck disable=SC2016 # literal backticks in human-readable prose
    printf '%s: missing top-level `concurrency:` (need `group:` to bound parallel runs on a ref)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
    ;;
  '!!map') ;;
  *)
    printf '%s: top-level concurrency has unexpected shape (tag=%s); expected map\n' \
      "${f}" "${conc_tag}" >&2
    failed=$((failed + 1))
    continue
    ;;
  esac

  group_tag="$(yq eval '.concurrency.group | tag' "${f}")"
  case "${group_tag}" in
  '!!null')
    # shellcheck disable=SC2016 # literal backticks in human-readable prose
    printf '%s: top-level concurrency is missing `group:`\n' "${f}" >&2
    failed=$((failed + 1))
    ;;
  '!!str')
    group_val="$(yq eval '.concurrency.group' "${f}")"
    if [[ -z ${group_val} ]]; then
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      printf '%s: top-level concurrency `group:` is empty\n' "${f}" >&2
      failed=$((failed + 1))
    fi
    ;;
  *)
    printf '%s: top-level concurrency.group has unexpected shape (tag=%s); expected string\n' \
      "${f}" "${group_tag}" >&2
    failed=$((failed + 1))
    ;;
  esac
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d workflow(s) missing or invalid top-level concurrency\n' "${failed}" >&2
  exit 1
fi
exit 0
