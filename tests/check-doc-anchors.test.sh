#!/usr/bin/env bash
# tests/check-doc-anchors.test.sh

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-doc-anchors.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-doc-anchors"

failures=0

function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r source_rel="$3"
  local -r expected_exit="$4"
  local -r expected_stderr="$5"

  local stderr_file
  stderr_file="$(mktemp)"

  local actual_exit=0
  DOC_ANCHOR_ROOT_OVERRIDE="${FIXTURES}/${fixture_dir}" \
    DOC_ANCHOR_SOURCES_OVERRIDE="${source_rel}" \
    "${SCRIPT}" >/dev/null 2>"${stderr_file}" || actual_exit=$?

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  harness_assert_record "${name}" "${expected_stderr}" "${stderr_file}"
  rm --force -- "${stderr_file}"
}

function main() {
  run_scenario 'good links pass' 'good' 'source.md' 0 ''
  run_scenario 'cross-file anchor miss fails' \
    'bad-anchor-miss' 'source.md' 1 \
    '[anchor-miss] source.md:3: #nonexistent-section not found in docs/target.md'
  run_scenario 'same-file anchor miss fails' \
    'bad-same-file' 'source.md' 1 \
    '[anchor-miss] source.md:3: #missing-anchor not found in source.md'
  run_scenario 'broken first link among multiple on one line fails' \
    'bad-multi-link' 'source.md' 1 \
    '[anchor-miss] source.md:3: #nonexistent not found in docs/target.md (available: good-heading)'

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
