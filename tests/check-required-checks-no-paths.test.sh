#!/usr/bin/env bash
# tests/check-required-checks-no-paths.test.sh
# @subject scripts/check-required-checks-no-paths.sh
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
fixtures="${REPO_ROOT}/tests/fixtures/required-checks"
script="${REPO_ROOT}/scripts/check-required-checks-no-paths.sh"

failures=0

run_scenario() {
  local -r name="$1"
  local -r fixture="$2"
  local -r expected_exit="$3"

  local -r tmpdir="$(mktemp -d)"
  trap 'rm -rf -- "${tmpdir}"' RETURN

  # Build a fake repo layout: docs/security/required-checks.md + the fixture workflow.
  mkdir -p "${tmpdir}/docs/security" "${tmpdir}/.github/workflows"
  sed "s|__SCENARIO__|${fixture}|g" \
    "${fixtures}/required-checks.md" >"${tmpdir}/docs/security/required-checks.md"
  cp "${fixtures}/${fixture}" "${tmpdir}/.github/workflows/${fixture}"

  # The script resolves workflow paths relative to its own CWD. cd into the fake repo.
  local actual_exit=0
  (cd "${tmpdir}" && "${script}" >/dev/null 2>&1) || actual_exit=$?

  if [[ ${actual_exit} -eq ${expected_exit} ]]; then
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  else
    printf 'FAIL: %s — expected exit %d, got %d\n' "${name}" "${expected_exit}" "${actual_exit}" >&2
    failures=$((failures + 1))
  fi
}

run_scenario 'ok fixture passes' 'ok.yml' 0
run_scenario 'paths: fixture fails' 'bad-paths.yml' 1
run_scenario 'paths-ignore: fixture fails' 'bad-paths-ignore.yml' 1

if ((failures > 0)); then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
