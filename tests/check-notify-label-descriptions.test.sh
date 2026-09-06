#!/usr/bin/env bash
# tests/check-notify-label-descriptions.test.sh
#
# Verdict + failure-mode matrix for
# scripts/check-notify-label-descriptions.sh. Every workflow a scenario
# reads is written into a temp directory at run time rather than kept
# under tests/fixtures/: one scenario needs a file that is not valid
# YAML, and a `.yml` on disk that no parser accepts fails the formatter
# before any harness runs.
set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-notify-label-descriptions.sh"

failures=0

# A description of exactly the cap, and one character past it. The cap is
# asserted from both sides so a change that moves the boundary by one
# cannot pass.
readonly AT_CAP='scorecard check(s) scored below 10, the payload was unreadable, or the scan could not run xxxxxxxxxx'
readonly OVER_CAP="${AT_CAP}x"

# @description Write a workflow that files one label through the notify
# composite.
# @arg $1 destination path  @arg $2 label  @arg $3 label description
function write_caller() {
  cat >"$1" <<EOF
name: caller
on:
  workflow_dispatch:
jobs:
  notify:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/notify-workflow-result
        with:
          label: $2
          label-description: "$3"
EOF
}

# @description Run the lint against a directory of workflows.
# @arg $1 scenario name  @arg $2 workflow dir  @arg $3 expected exit
# @arg $4 expected output substring (empty skips)
function run_scenario() {
  local -r name="$1" dir="$2" expected_exit="$3" expected_msg="$4"
  local out_file outcome_file
  out_file="$(mktemp)"
  outcome_file="$(mktemp)"
  local actual_exit=0
  WORKFLOWS_DIR_OVERRIDE="${dir}" "${SCRIPT}" >"${out_file}" 2>&1 || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_msg} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_msg}" "${out_file}"; then
    printf 'FAIL: %s — output missing %q\n' "${name}" "${expected_msg}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi
  harness_assert_record "${name}" "${expected_msg}" "${outcome_file}" "${out_file}"
  rm --force -- "${outcome_file}" "${out_file}"
}

function main() {
  local root
  root="$(mktemp --directory)"

  # A description at the cap passes: the boundary belongs to the legal
  # side, which is what the API accepts.
  mkdir -p "${root}/at-cap"
  write_caller "${root}/at-cap/a.yml" 'alpha-drift' "${AT_CAP}"
  run_scenario 'a description exactly at the cap passes' "${root}/at-cap" 0 \
    '1 label description(s) across 1 caller workflow(s)'

  # One character past the cap is a description the labels API rejects,
  # so the wording in the tree can never reach the label.
  mkdir -p "${root}/over-cap"
  write_caller "${root}/over-cap/a.yml" 'alpha-drift' "${OVER_CAP}"
  run_scenario 'a description one character past the cap fails' "${root}/over-cap" 1 \
    'label alpha-drift description is 101 characters, over the 100-character cap'

  # Two workflows filing one label with different wording overwrite each
  # other on every run, so the description a maintainer sees is whichever
  # ran last.
  mkdir -p "${root}/conflict"
  write_caller "${root}/conflict/a.yml" 'beta-drift' 'beta drifted, or the check could not run'
  write_caller "${root}/conflict/b.yml" 'beta-drift' 'beta drifted'
  run_scenario 'one label with two descriptions fails' "${root}/conflict" 1 \
    'label beta-drift is filed with more than one description'

  # A scan set holding workflows but no notify caller means the composite
  # moved or was renamed. Scored clean, that is a lint reporting on a
  # composite it never found.
  mkdir -p "${root}/no-caller"
  cat >"${root}/no-caller/a.yml" <<'EOF'
name: no caller
on:
  workflow_dispatch:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: 'true'
EOF
  run_scenario 'a scan set with no notify caller is a could-not-run' "${root}/no-caller" 2 \
    'none uses .github/actions/notify-workflow-result'

  # A workflow the parser cannot read is a workflow this lint did not
  # examine, which must not be scored as one holding no violation.
  mkdir -p "${root}/unparsable"
  printf 'jobs: [\n  this is not: valid: yaml\n' >"${root}/unparsable/a.yml"
  run_scenario 'an unparsable workflow is a could-not-run' "${root}/unparsable" 2 \
    'could not be parsed'

  # An empty scan root is the deliberate-fixture case the shared
  # enumeration helper gates behind LINT_ALLOW_EMPTY_SCAN.
  mkdir -p "${root}/empty"
  local out_file actual_exit=0
  out_file="$(mktemp)"
  WORKFLOWS_DIR_OVERRIDE="${root}/empty" "${SCRIPT}" >"${out_file}" 2>&1 || actual_exit=$?
  if [[ ${actual_exit} -ne 2 ]] ||
    ! grep --fixed-strings --quiet -- 'empty scan set' "${out_file}"; then
    printf 'FAIL: an empty scan root is a could-not-run — exit %d\n' "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: an empty scan root is a could-not-run (exit %d)\n' "${actual_exit}"
  fi
  rm --force -- "${out_file}"

  rm --recursive --force -- "${root}"

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
