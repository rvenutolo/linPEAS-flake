#!/usr/bin/env bash
# tests/run-lint-group.test.sh
#
# Failure-mode harness for scripts/run-lint-group.sh. Builds a throwaway
# manifest + stub check scripts in a temp dir, drives the runner via the
# *_OVERRIDE env vars, and asserts exit codes, the summary table, and
# that one failing check does NOT abort the rest of the group.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/run-lint-group.sh"

failures=0

# @arg $1 scenario name
# @arg $2 group arg to pass
# @arg $3 expected exit
# @arg $4 expected stdout substring (empty skips)
function run_scenario() {
  local -r name="$1" group="$2" expected_exit="$3" expected_out="$4"
  local out_file step_file work scripts_dir tests_dir manifest
  work="$(mktemp -d)"
  scripts_dir="${work}/scripts"
  tests_dir="${work}/tests"
  manifest="${work}/lint-groups.yml"
  mkdir -p "${scripts_dir}" "${tests_dir}"

  # Two passing checks + one failing, to prove don't-abort-on-fail.
  printf '#!/usr/bin/env bash\nexit 0\n' >"${scripts_dir}/check-aaa.sh"
  printf '#!/usr/bin/env bash\nexit 1\n' >"${scripts_dir}/check-bbb.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${scripts_dir}/check-ccc.sh"
  chmod +x "${scripts_dir}"/check-*.sh
  cat >"${manifest}" <<YAML
demo-all-pass:
  - aaa
  - ccc
demo-one-fail:
  - aaa
  - bbb
  - ccc
demo-missing:
  - aaa
  - nope
YAML

  out_file="$(mktemp)"
  step_file="$(mktemp)"
  local actual_exit=0
  LINT_GROUPS_OVERRIDE="${manifest}" \
    SCRIPTS_DIR_OVERRIDE="${scripts_dir}" \
    TESTS_DIR_OVERRIDE="${tests_dir}" \
    GITHUB_STEP_SUMMARY="${step_file}" \
    "${SCRIPT}" "${group}" >"${out_file}" 2>&1 || actual_exit=$?

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_out} ]] && ! grep --fixed-strings --quiet -- "${expected_out}" "${out_file}"; then
    printf 'FAIL: %s — stdout missing %q\n' "${name}" "${expected_out}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ ${expected_exit} -lt 2 ]] && ! grep --fixed-strings --quiet -- '### ' "${step_file}"; then
    # Config errors (exit 2) bail before the table; only assert the
    # $GITHUB_STEP_SUMMARY write when checks actually ran.
    printf 'FAIL: %s — GITHUB_STEP_SUMMARY missing table header\n' "${name}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi
  rm --recursive --force -- "${work}" "${out_file}" "${step_file}"
}

function main() {
  run_scenario 'all checks pass -> exit 0' 'demo-all-pass' 0 '| aaa |'
  run_scenario 'one check fails -> exit 1' 'demo-one-fail' 1 'FAIL'
  # don't-abort: ccc must still appear in the table after bbb failed
  run_scenario 'failing check does not abort the rest' 'demo-one-fail' 1 '| ccc |'
  run_scenario 'missing script -> exit 1' 'demo-missing' 1 'FAIL'
  run_scenario 'unknown group -> exit 2' 'no-such-group' 2 ''

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d scenario(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
