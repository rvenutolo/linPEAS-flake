#!/usr/bin/env bash
# tests/check-cron-table.test.sh
#
# Failure-mode harness for scripts/check-cron-table.sh.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-cron-table.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-cron-table"

failures=0

# @description Run the script with fixture overrides; assert exit code and stderr.
# @arg $1 scenario name
# @arg $2 workflows directory under FIXTURES/<scenario>/
# @arg $3 ci.md path under FIXTURES/<scenario>/
# @arg $4 expected exit code (0, 1, or 2)
# @arg $5 expected stderr substring (empty string skips the check)
function run_scenario() {
  local -r name="$1"
  local -r workflows_dir="$2"
  local -r doc_file="$3"
  local -r expected_exit="$4"
  local -r expected_stderr="$5"

  local stderr_file
  stderr_file="$(mktemp)"

  local actual_exit=0
  WORKFLOWS_DIR_OVERRIDE="${workflows_dir}" \
    DOC_FILE_OVERRIDE="${doc_file}" \
    "${SCRIPT}" >/dev/null 2>"${stderr_file}" || actual_exit=$?

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm --force -- "${stderr_file}"
}

function main() {
  run_scenario 'good fixtures pass' \
    "${FIXTURES}/good/workflows" \
    "${FIXTURES}/good/ci.md" \
    0 ''

  run_scenario 'workflow on disk absent from table fails' \
    "${FIXTURES}/bad-missing-in-table/workflows" \
    "${FIXTURES}/bad-missing-in-table/ci.md" \
    1 'missing-in-table'

  run_scenario 'table row without matching workflow file fails' \
    "${FIXTURES}/bad-missing-on-disk/workflows" \
    "${FIXTURES}/bad-missing-on-disk/ci.md" \
    1 'missing-on-disk'

  run_scenario 'cron string mismatch between workflow and table fails' \
    "${FIXTURES}/bad-cron-mismatch/workflows" \
    "${FIXTURES}/bad-cron-mismatch/ci.md" \
    1 'cron-mismatch'

  run_scenario 'arrow list with wrong workflow name fails' \
    "${FIXTURES}/bad-arrow-name/workflows" \
    "${FIXTURES}/bad-arrow-name/ci.md" \
    1 'arrow-order'

  run_scenario 'arrow list with non-increasing times fails' \
    "${FIXTURES}/bad-arrow-order/workflows" \
    "${FIXTURES}/bad-arrow-order/ci.md" \
    1 'arrow-order'

  run_scenario 'missing workflows dir exits 2' \
    '/nonexistent/workflows' \
    "${FIXTURES}/good/ci.md" \
    2 'missing'

  run_scenario 'missing doc file exits 2' \
    "${FIXTURES}/good/workflows" \
    '/nonexistent/ci.md' \
    2 'missing'

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
