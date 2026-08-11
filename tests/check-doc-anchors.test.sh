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

# @description Run the lint over a fixture root; assert exit code, stderr, and
# — on the clean path — the summary line naming what was resolved. The tally
# of slugs that lost characters is what separates the clean scenarios: they
# exercise different arms of the slug algorithm, and every one of them
# otherwise ends in the same silent success.
# @arg $1 name  @arg $2 fixture dir  @arg $3 source rel path
# @arg $4 expected exit  @arg $5 stderr substring  @arg $6 stdout substring
function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r source_rel="$3"
  local -r expected_exit="$4"
  local -r expected_stderr="$5"
  local -r expected_stdout="${6:-}"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  DOC_ANCHOR_ROOT_OVERRIDE="${FIXTURES}/${fixture_dir}" \
    DOC_ANCHOR_SOURCES_OVERRIDE="${source_rel}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"

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
  elif [[ -n ${expected_stdout} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stdout}" "${stdout_file}"; then
    printf 'FAIL: %s — stdout missing %q\n' "${name}" "${expected_stdout}" >&2
    cat -- "${stdout_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  if [[ -n ${expected_stdout} ]]; then
    harness_assert_also "${expected_stdout}"
  fi
  rm --force -- "${outcome_file}" "${stdout_file}" "${stderr_file}"
}

function main() {
  # Two links, one cross-file and one same-file, so two target files are
  # resolved and neither heading loses a character to slugging.
  run_scenario 'good links pass' 'good' 'source.md' 0 '' \
    'ok — 2 anchor link(s) in 1 source file(s) resolved against 3 anchor(s) in 2 target file(s); 0 heading(s) required character deletion'
  run_scenario 'cross-file anchor miss fails' \
    'bad-anchor-miss' 'source.md' 1 \
    '[anchor-miss] source.md:3: #nonexistent-section not found in docs/target.md'
  run_scenario 'same-file anchor miss fails' \
    'bad-same-file' 'source.md' 1 \
    '[anchor-miss] source.md:3: #missing-anchor not found in source.md'
  run_scenario 'broken first link among multiple on one line fails' \
    'bad-multi-link' 'source.md' 1 \
    '[anchor-miss] source.md:3: #nonexistent not found in docs/target.md (available: good-heading)'
  run_scenario 'heading inside a code fence is not a slug source' \
    'bad-fenced-heading' 'source.md' 1 \
    '[anchor-miss] source.md:3: #fenced-phantom not found in docs/target.md (available: fence-target)'
  # `_` survives the delete step, so no heading is counted lossy.
  run_scenario 'underscore is preserved in the slug' \
    'good-underscore' 'source.md' 0 '' \
    'ok — 1 anchor link(s) in 1 source file(s) resolved against 2 anchor(s) in 1 target file(s); 0 heading(s) required character deletion'
  # The apostrophe is deleted, so exactly one of the target's two headings
  # slugs lossily — the arm where GFM and mkdocs-material can disagree.
  run_scenario 'apostrophe is deleted from the slug' \
    'good-apostrophe' 'source.md' 0 '' \
    'ok — 1 anchor link(s) in 1 source file(s) resolved against 2 anchor(s) in 1 target file(s); 1 heading(s) required character deletion'

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
