#!/usr/bin/env bash
# tests/check-ephemeral-refs.test.sh

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/check-ephemeral-refs.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-ephemeral-refs"

failures=0

# @description Run the lint against one fixture and assert its exit code
# plus a stderr substring.
# @arg $1 name human-readable scenario name
# @arg $2 fixture_dir fixture directory under FIXTURES (used as REPO_ROOT)
# @arg $3 source_rel source file relative to the fixture REPO_ROOT
# @arg $4 mode extra flag passed to the script (empty or "--advisory")
# @arg $5 expected_exit expected exit status
# @arg $6 expected_stderr stderr substring that must be present (empty to skip)
function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r source_rel="$3"
  local -r mode="$4"
  local -r expected_exit="$5"
  local -r expected_stderr="$6"

  local stderr_file
  stderr_file="$(mktemp)"

  local -a args=()
  [[ -n ${mode} ]] && args+=("${mode}")

  local actual_exit=0
  EPHEMERAL_REFS_ROOT_OVERRIDE="${FIXTURES}/${fixture_dir}" \
    EPHEMERAL_REFS_SOURCES_OVERRIDE="${source_rel}" \
    "${SCRIPT}" "${args[@]}" >/dev/null 2>"${stderr_file}" || actual_exit=$?

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

  rm --force -- "${stderr_file}"
}

# @description Assert that banned shapes inside a tilde (`~~~`) code
# fence are stripped. The fixture is built at runtime in a temp dir so
# the Markdown formatter cannot normalize the tilde fence to backticks.
function run_tilde_scenario() {
  local tmp_root
  tmp_root="$(mktemp -d)"
  mkdir -p "${tmp_root}/docs"
  printf '# t\n\n~~~\nref #123 on 2026-06-18 Phase 2 (D3) .claude/x.md\n~~~\n' \
    >"${tmp_root}/docs/tilde.md"

  local actual_exit=0
  EPHEMERAL_REFS_ROOT_OVERRIDE="${tmp_root}" \
    EPHEMERAL_REFS_SOURCES_OVERRIDE='docs/tilde.md' \
    "${SCRIPT}" >/dev/null 2>&1 || actual_exit=$?

  if [[ ${actual_exit} -ne 0 ]]; then
    printf 'FAIL: tilde-fenced banned shapes pass — expected exit 0, got %d\n' \
      "${actual_exit}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: tilde-fenced banned shapes pass (exit 0)\n'
  fi

  rm --recursive --force -- "${tmp_root}"
}

function main() {
  run_scenario 'good prose passes' 'good' 'source.md' '' 0 ''
  run_scenario 'bare issue ref fails' \
    'bad-issue-ref' 'source.md' '' 1 '[issue-ref]'
  run_scenario 'prose date fails' \
    'bad-date' 'source.md' '' 1 '[date]'
  run_scenario 'planning label fails' \
    'bad-planning' 'source.md' '' 1 '[planning]'
  run_scenario 'review-pass label fails' \
    'bad-review' 'source.md' '' 1 '[review]'
  # Enumerated shapes that legitimately start a match must still report.
  run_scenario 'standalone planning shapes still match' \
    'planning-shapes' 'source.md' '' 1 '[planning]'
  run_scenario 'standalone review shapes still match' \
    'review-shapes' 'source.md' '' 1 '[review]'
  # Mid-word matches (UTF-8 -> F-8, ID5: -> D5:) must not be smuggled
  # back into the blocking gate by the bare planning/review shapes.
  run_scenario 'encoding shapes are not planning/review labels' \
    'false-positive-shapes' 'source.md' '' 0 ''
  # An unterminated generated block must fail loud, not blank to EOF.
  run_scenario 'unterminated generated block errors' \
    'bad-unterminated-genblock' 'source.md' '' 1 'unterminated generated block'
  run_scenario 'literal .claude path fails' \
    'bad-claude-path' 'source.md' '' 1 '[claude-path]'
  run_scenario 'code-span/block banned shapes pass' \
    'exempt-codeblock' 'source.md' '' 0 ''
  run_scenario 'generated-block banned shapes pass' \
    'exempt-genblock' 'source.md' '' 0 ''
  run_tilde_scenario
  run_scenario 'causal phrase passes blocking pass' \
    'advisory' 'source.md' '' 0 ''
  run_scenario 'causal phrase prints in advisory mode' \
    'advisory' 'source.md' '--advisory' 0 '[advisory]'

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
