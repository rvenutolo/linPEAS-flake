#!/usr/bin/env bash
# tests/check-actionlint-pyflakes-active.test.sh

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-actionlint-pyflakes-active.sh"

failures=0

function run_scenario() {
  local -r name="$1"
  local -r fixture_override="$2"
  local -r expected_exit="$3"
  local -r expected_stderr_substr="$4"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  ACTIONLINT_PYFLAKES_FIXTURE_OVERRIDE="${fixture_override}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"

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

  harness_assert_record "${name}" "${expected_stderr_substr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  rm -f -- "${outcome_file}" "${stdout_file}" "${stderr_file}"
}

# Default fixture (unset override) — must pass.
function scenario_default_passes() {
  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"
  local actual_exit=0
  "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  if [[ ${actual_exit} -ne 0 ]]; then
    printf 'FAIL: default fixture — expected exit 0, got %d\n' "${actual_exit}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: default fixture\n'
  fi
  harness_assert_record 'default fixture' '' \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  rm -f -- "${outcome_file}" "${stdout_file}" "${stderr_file}"
}

scenario_default_passes

# The canary guards the `-pyflakes=` pin. Its pre-commit `files` filter
# must match wherever that pin lives, or editing the pin alone does not
# re-trigger the canary on the per-changed-file commit path. Derived from
# the tree, not hardcoded: if the pin moves to another nix module, this
# fails until the filter follows.
function scenario_hook_watches_pin() {
  local -a pin_files=()
  local f
  while IFS= read -r f; do
    [[ -z ${f} ]] && continue
    pin_files+=("${f#"${REPO_ROOT}/"}")
  done < <(grep --recursive --files-with-matches --include='*.nix' \
    --fixed-strings -- '-pyflakes=' "${REPO_ROOT}/nix" | sort)

  # Guard-the-guard: an empty result means the pin moved out of nix/ or
  # was renamed. Fail loud rather than vacuously pass.
  if [[ ${#pin_files[@]} -eq 0 ]]; then
    printf 'FAIL: no nix/**/*.nix file contains the -pyflakes= pin\n' >&2
    failures=$((failures + 1))
    return
  fi

  local files_re
  files_re="$(awk '
    /^  actionlint-pyflakes-active = \{/ { in_block = 1; next }
    in_block && /^  \};/ { exit }
    in_block && match($0, /files = "[^"]*"/) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^files = "/, "", s)
      sub(/"$/, "", s)
      print s
      exit
    }
  ' "${REPO_ROOT}/nix/hooks/workflow-security.nix")"

  if [[ -z ${files_re} ]]; then
    printf 'FAIL: could not extract files filter for actionlint-pyflakes-active\n' >&2
    failures=$((failures + 1))
    return
  fi

  # Nix string literal: "\\." in source is the ERE "\.".
  local ere
  ere="$(printf '%s' "${files_re}" | sed 's/\\\\/\\/g')"

  local p missing=0
  for p in "${pin_files[@]}"; do
    if ! printf '%s\n' "${p}" |
      grep --quiet --extended-regexp -- "${ere}"; then
      printf 'FAIL: hook files filter does not match %s (the pin lives there)\n' \
        "${p}" >&2
      missing=1
    fi
  done
  if ((missing)); then
    failures=$((failures + 1))
  else
    printf 'PASS: hook files filter covers the -pyflakes= pin\n'
  fi
}

scenario_hook_watches_pin

# Override pointing at a clean workflow (no python run:) — must fail
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
run_scenario "no pyflakes finding → fails" \
  "${clean_fixture}" 1 "no pyflakes finding"
rm -f -- "${clean_fixture}"

# An absent fixture leaves the canary unable to observe anything. That is a
# broken environment, not a wiring regression, so it carries the
# could-not-run code rather than the canary's failure code.
run_scenario "missing fixture → could not run" \
  '/nonexistent/actionlint-pyflakes-smoke.yml' 2 "fixture not found"

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -ne 0 ]]; then
  printf '\n%d scenario(s) failed.\n' "${failures}" >&2
  exit 1
fi
printf '\nAll scenarios passed.\n'
