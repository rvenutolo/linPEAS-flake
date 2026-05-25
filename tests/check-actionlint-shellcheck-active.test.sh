#!/usr/bin/env bash
# tests/check-actionlint-shellcheck-active.test.sh

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/check-actionlint-shellcheck-active.sh"

failures=0

function run_scenario() {
  local -r name="$1"
  local -r fixture_override="$2"
  local -r expected_exit="$3"
  local -r expected_stderr_substr="$4"

  local stderr_file
  stderr_file="$(mktemp)"

  local actual_exit=0
  ACTIONLINT_SMOKE_FIXTURE_OVERRIDE="${fixture_override}" \
    "${SCRIPT}" >/dev/null 2>"${stderr_file}" || actual_exit=$?

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stderr_substr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr_substr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr_substr}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm -f -- "${stderr_file}"
}

# Default fixture (unset override) — must pass.
function scenario_default_passes() {
  local stderr_file
  stderr_file="$(mktemp)"
  local actual_exit=0
  "${SCRIPT}" >/dev/null 2>"${stderr_file}" || actual_exit=$?
  if [[ ${actual_exit} -ne 0 ]]; then
    printf 'FAIL: default fixture — expected exit 0, got %d\n' "${actual_exit}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: default fixture\n'
  fi
  rm -f -- "${stderr_file}"
}

scenario_default_passes

# Override pointing at a clean workflow (no SC2086) — must fail
# because the canary expects shellcheck to surface a finding.
clean_fixture="$(mktemp --suffix=.yml)"
cat >"${clean_fixture}" <<'YAML'
name: clean
on: push
permissions: {}
jobs:
  c:
    runs-on: ubuntu-latest
    steps:
      - run: echo "hello"
YAML
run_scenario "missing SC2086 → fails" \
  "${clean_fixture}" 1 "SC2086 not found"
rm -f -- "${clean_fixture}"

if [[ ${failures} -ne 0 ]]; then
  printf '\n%d scenario(s) failed.\n' "${failures}" >&2
  exit 1
fi
printf '\nAll scenarios passed.\n'
