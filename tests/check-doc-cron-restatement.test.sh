#!/usr/bin/env bash
# tests/check-doc-cron-restatement.test.sh
#
# Failure-mode harness for scripts/check-doc-cron-restatement.sh.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-doc-cron-restatement.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-doc-cron-restatement"

failures=0

# @description Run the script with fixture overrides; assert exit code and stderr.
# @arg $1 scenario name
# @arg $2 workflows directory under FIXTURES/<scenario>/
# @arg $3 scan root under FIXTURES/<scenario>/
# @arg $4 expected exit code (0, 1, or 2)
# @arg $5 expected stderr substring (empty string skips the check)
function run_scenario() {
  local -r name="$1"
  local -r workflows_dir="$2"
  local -r scan_root="$3"
  local -r expected_exit="$4"
  local -r expected_stderr="$5"

  local stderr_file
  stderr_file="$(mktemp)"

  local actual_exit=0
  WORKFLOWS_DIR_OVERRIDE="${workflows_dir}" \
    SCAN_ROOT_OVERRIDE="${scan_root}" \
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

  harness_assert_record "${name}" "${expected_stderr}" "${stderr_file}"
  rm --force -- "${stderr_file}"
}

function main() {
  run_scenario 'literal-time restatement of a workflow name fails' \
    "${FIXTURES}/restatement-fails/workflows" \
    "${FIXTURES}/restatement-fails" \
    1 'docs/x.md'

  run_scenario 'yml-suffixed name with a clock time fails' \
    "${FIXTURES}/yml-suffixed-fails/workflows" \
    "${FIXTURES}/yml-suffixed-fails" \
    1 'docs/x.md'

  run_scenario 'cadence word without a clock time passes' \
    "${FIXTURES}/cadence-only-passes/workflows" \
    "${FIXTURES}/cadence-only-passes" \
    0 ''

  run_scenario 'bare common word near a time does not false-positive' \
    "${FIXTURES}/bare-common-word-passes/workflows" \
    "${FIXTURES}/bare-common-word-passes" \
    0 ''

  run_scenario 'restatement inside ci.md is exempt' \
    "${FIXTURES}/ci-md-exempt/workflows" \
    "${FIXTURES}/ci-md-exempt" \
    0 ''

  run_scenario 'README ci-summary block is exempt' \
    "${FIXTURES}/readme-block-exempt/workflows" \
    "${FIXTURES}/readme-block-exempt" \
    0 ''

  run_scenario 'README restatement outside the ci-summary block fails' \
    "${FIXTURES}/readme-outside-block-fails/workflows" \
    "${FIXTURES}/readme-outside-block-fails" \
    1 'README.md'

  run_scenario 'missing workflows dir exits 2' \
    '/nonexistent/workflows' \
    "${FIXTURES}/missing-workflows-dir" \
    2 ''

  # .yaml workflow extension: fixed once the discovery glob covers *.yaml too.
  run_scenario '.yaml-suffixed name with a clock time fails' \
    "${FIXTURES}/yaml-suffixed-fails/workflows" \
    "${FIXTURES}/yaml-suffixed-fails" \
    1 'docs/x.md'

  # A doc filename holding a newline splits across the script's
  # newline-delimited file handoff into two paths that do not exist, so the
  # line producer cannot open either and the restatement below goes
  # unscanned. That must be a tooling fault, not a clean verdict. Built at
  # run time rather than checked in because treefmt walks tests/fixtures and
  # its exclude list cannot express a path containing a newline.
  local split_root
  split_root="$(mktemp --directory)"
  mkdir --parents "${split_root}/docs" "${split_root}/workflows"
  printf 'name: Pages\non:\n  schedule:\n    - cron: "17 3 * * *"\n' \
    >"${split_root}/workflows/pages.yml"
  printf 'The pages.yml workflow runs at 03:17 UTC.\n' \
    >"${split_root}/docs/$(printf 'split\nname').md"
  run_scenario 'unopenable doc path exits 2 rather than scoring it clean' \
    "${split_root}/workflows" \
    "${split_root}" \
    2 'readable_lines failed for'
  rm --recursive --force -- "${split_root}"

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
