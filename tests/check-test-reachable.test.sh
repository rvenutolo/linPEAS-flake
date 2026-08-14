#!/usr/bin/env bash
# tests/check-test-reachable.test.sh
#
# Fixture harness for scripts/check-test-reachable.sh. Builds temp
# tests/runner/lint-group/workflow fixtures via the *_OVERRIDE env vars and
# asserts a harness is reachable via each of the four runner mechanisms, and
# that a harness reachable by none is reported and fails.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-test-reachable.sh"

failures=0
function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# @description Run the guard against a scenario dir. Expects a `${dir}/tests`
# harness dir; optional `${dir}/run-harness-group.sh`, `${dir}/lint-groups.yml`,
# `${dir}/workflows/`. Asserts exit code, (on failure) a stderr substring, and
# (on the clean path) the summary line naming the runner that reached the
# harness. The runner tally is what separates the clean scenarios: each
# exercises a different reachability mechanism, and without it every clean run
# is the same observable outcome.
# @arg $1 name  @arg $2 dir  @arg $3 expected exit  @arg $4 stderr substring
# @arg $5 stdout substring (empty skips the check)
function assert_run() {
  local -r name="$1" dir="$2" expected_exit="$3" expected_stderr="$4"
  local -r expected_stdout="${5:-}"
  local stderr_file stdout_file outcome_file actual_exit=0
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"
  # A fixture tree holds only the harnesses a scenario needs, so a scan
  # root the scenario does not exercise is deliberately empty here. The
  # breadth assertion those roots carry against the real tree is held by
  # tests/glob-scan-breadth.test.sh, which points each one at an empty
  # directory on purpose.
  LINT_ALLOW_EMPTY_SCAN=1 \
    TESTS_DIR_OVERRIDE="${dir}/tests" \
    HARNESS_RUNNER_OVERRIDE="${dir}/run-harness-group.sh" \
    LINT_GROUPS_OVERRIDE="${dir}/lint-groups.yml" \
    WORKFLOWS_DIR_OVERRIDE="${dir}/workflows" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  if [[ -n ${expected_stdout} ]]; then
    harness_assert_also "${expected_stdout}"
  fi
  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    fail "${name} — expected exit ${expected_exit}, got ${actual_exit}"
    cat -- "${stderr_file}" >&2
  elif [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    fail "${name} — stderr missing '${expected_stderr}'"
    cat -- "${stderr_file}" >&2
  elif [[ -n ${expected_stdout} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stdout}" "${stdout_file}"; then
    fail "${name} — stdout missing '${expected_stdout}'"
    cat -- "${stdout_file}" >&2
  else
    pass "${name} (exit ${actual_exit})"
  fi
  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
}

# @description Scaffold a scenario dir with empty tests/workflows and an empty
# runner/lint-groups so each mechanism can be exercised in isolation.
# @arg $1 dir
function scaffold() {
  local -r dir="$1"
  mkdir -p "${dir}/tests" "${dir}/workflows"
  printf 'readonly -a HARNESSES=(\n)\n' >"${dir}/run-harness-group.sh"
  printf '# empty\n' >"${dir}/lint-groups.yml"
}

function main() {
  local dir

  # 1. Reachable via the harness-group HARNESSES array.
  dir="$(mktemp --directory)"
  scaffold "${dir}"
  : >"${dir}/tests/foo.test.sh"
  printf "readonly -a HARNESSES=(\n  'foo|foo.test.sh|'\n)\n" >"${dir}/run-harness-group.sh"
  assert_run 'reachable via HARNESSES array' "${dir}" 0 '' \
    'run-harness-group.sh HARNESSES array: 1'
  rm --recursive --force -- "${dir}"

  # 2. Orphan reachable by nothing -> exit 1, named.
  dir="$(mktemp --directory)"
  scaffold "${dir}"
  : >"${dir}/tests/foo.test.sh"
  : >"${dir}/tests/orphan.test.sh"
  printf "readonly -a HARNESSES=(\n  'foo|foo.test.sh|'\n)\n" >"${dir}/run-harness-group.sh"
  assert_run 'orphan harness fails and is named' "${dir}" 1 \
    'unreachable test harness (no runner executes it): orphan.test.sh'
  rm --recursive --force -- "${dir}"

  # 3. Reachable via a lint-groups member (check-<name>.test.sh).
  dir="$(mktemp --directory)"
  scaffold "${dir}"
  : >"${dir}/tests/check-bar.test.sh"
  printf 'lint-x:\n  - bar\n' >"${dir}/lint-groups.yml"
  assert_run 'reachable via lint-groups member' "${dir}" 0 '' \
    'run-lint-group.sh lint-groups member: 1'
  rm --recursive --force -- "${dir}"

  # 4. Reachable via the refresh-*.test.sh name convention.
  dir="$(mktemp --directory)"
  scaffold "${dir}"
  : >"${dir}/tests/refresh-baz.test.sh"
  assert_run 'reachable via refresh-* glob' "${dir}" 0 '' \
    'run-doc-freshness.sh refresh-* glob: 1'
  rm --recursive --force -- "${dir}"

  # 5. Reachable via a direct workflow invocation.
  dir="$(mktemp --directory)"
  scaffold "${dir}"
  : >"${dir}/tests/qux.test.sh"
  printf 'jobs:\n  x:\n    steps:\n      - run: bash tests/qux.test.sh\n' \
    >"${dir}/workflows/ci.yml"
  assert_run 'reachable via direct workflow invocation' "${dir}" 0 '' \
    'direct workflow invocation: 1'
  rm --recursive --force -- "${dir}"

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
