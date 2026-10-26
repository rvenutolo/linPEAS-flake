#!/usr/bin/env bash
# tests/check-actionlint-runner-labels-needed.test.sh

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-actionlint-runner-labels-needed.sh"

failures=0

# @description Run the canary against a config and check its exit code and,
# when given, a stderr substring and a substring stderr must NOT carry.
# @arg $1 scenario name
# @arg $2 config override path; empty runs against the live config
# @arg $3 expected exit code
# @arg $4 expected stderr substring, or empty
# @arg $5 stderr substring that must be absent, or empty
function run_scenario() {
  local -r name="$1"
  local -r config_override="$2"
  local -r expected_exit="$3"
  local -r expected_stderr_substr="$4"
  local -r absent_stderr_substr="$5"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  if [[ -n ${config_override} ]]; then
    ACTIONLINT_CONFIG_OVERRIDE="${config_override}" \
      "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  else
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  fi
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
  elif [[ -n ${absent_stderr_substr} ]] &&
    grep --fixed-strings --quiet -- "${absent_stderr_substr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr unexpectedly carries %q\n' "${name}" "${absent_stderr_substr}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  harness_assert_record "${name}" "${expected_stderr_substr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  rm -f -- "${outcome_file}" "${stdout_file}" "${stderr_file}"
}

fixture_dir="$(mktemp --directory)"
trap 'rm -rf -- "${fixture_dir}"' EXIT

# The live allowlist must hold only labels actionlint still rejects; this
# is the scenario that fires once an actionlint bump learns one of them.
run_scenario 'live allowlist still needed' '' 0 '' ''

# A label actionlint already knows is a dead entry.
printf 'self-hosted-runner:\n  labels:\n    - ubuntu-24.04-arm\n' \
  >"${fixture_dir}/known.yaml"
run_scenario 'known label → fires' "${fixture_dir}/known.yaml" 1 \
  'accepts runner label "ubuntu-24.04-arm"' ''

# Only the dead entry is named; the label still rejected is left alone.
printf 'self-hosted-runner:\n  labels:\n    - ubuntu-24.04-arm\n    - not-a-hosted-label\n' \
  >"${fixture_dir}/mixed.yaml"
run_scenario 'mixed allowlist → names only the dead entry' \
  "${fixture_dir}/mixed.yaml" 1 \
  'accepts runner label "ubuntu-24.04-arm"' 'not-a-hosted-label'

# An allowlist with nothing in it gives the canary nothing to observe.
printf 'self-hosted-runner:\n  labels: []\n' >"${fixture_dir}/empty.yaml"
run_scenario 'empty allowlist → could not run' "${fixture_dir}/empty.yaml" 2 \
  'lists no self-hosted-runner label' ''

printf 'self-hosted-runner: [\n' >"${fixture_dir}/malformed.yaml"
run_scenario 'unparsable config → could not run' "${fixture_dir}/malformed.yaml" 2 \
  'cannot read self-hosted-runner.labels' ''

run_scenario 'missing config → could not run' \
  '/nonexistent/actionlint.yaml' 2 'config not found' ''

# actionlint reads a label written as an alias as its anchored text, so
# each aliased allowlist below reaches the verdict of its inline twin
# above. Each names its own config path, so no two outputs match.
printf 'x-dead: &dead ubuntu-24.04-arm\nx-needed: &needed not-a-hosted-label\nself-hosted-runner:\n  labels:\n    - *dead\n    - *needed\n' \
  >"${fixture_dir}/alias-mixed.yaml"
run_scenario 'aliased mixed allowlist → names only the dead entry' \
  "${fixture_dir}/alias-mixed.yaml" 1 \
  'accepts runner label "ubuntu-24.04-arm"' 'not-a-hosted-label'

# A list written as an alias whose item is an alias is read through both.
printf 'x-dead: &dead ubuntu-24.04-arm\nx-labels: &labels [*dead]\nself-hosted-runner:\n  labels: *labels\n' \
  >"${fixture_dir}/alias-deep.yaml"
run_scenario 'aliased list of aliased labels → fires' \
  "${fixture_dir}/alias-deep.yaml" 1 \
  'accepts runner label "ubuntu-24.04-arm"' ''

# An alias chain under a key the canary does not read changes nothing.
printf 'x-dead: &dead ubuntu-24.04-arm\nx-chain: &chain [*dead]\nunread: [*chain]\nself-hosted-runner:\n  labels:\n    - ubuntu-24.04-arm\n' \
  >"${fixture_dir}/alias-unread.yaml"
run_scenario 'alias chain outside the labels → fires as inline' \
  "${fixture_dir}/alias-unread.yaml" 1 \
  'accepts runner label "ubuntu-24.04-arm"' ''

# One pass resolves one level of an alias chain, and a label is a
# scalar, so only an item that is itself a collection holding an alias
# can stay one. The canary cannot probe that text, so it does not run.
printf 'x-dead: &dead ubuntu-24.04-arm\nx-chain: &chain [*dead]\nself-hosted-runner:\n  labels:\n    - *chain\n' \
  >"${fixture_dir}/alias-residual.yaml"
run_scenario 'label still holding an alias after resolving → could not run' \
  "${fixture_dir}/alias-residual.yaml" 2 \
  'self-hosted-runner.labels still holds a YAML alias after resolving; cannot read it' ''

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -ne 0 ]]; then
  printf '\n%d scenario(s) failed.\n' "${failures}" >&2
  exit 1
fi
printf '\nAll scenarios passed.\n'
