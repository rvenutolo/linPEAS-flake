#!/usr/bin/env bash
# scripts/check-script-has-test.sh
#
# @description Lint: every `scripts/check-*.sh` has a matching
# `tests/check-*.test.sh` and vice versa, modulo an explicit EXEMPT
# list.

# Lint: every `scripts/check-*.sh` must have a matching
# `tests/check-*.test.sh`, and every `tests/check-*.test.sh` must
# have a matching `scripts/check-*.sh`. The pairing is held by
# convention today; lint forecloses regression so a new check script
# can't ship without a test harness.
#
# The lint runs in both directions:
#   forward  — every lint script has its test
#   reverse  — every check-named test corresponds to a real script
#
# EXEMPT: `check-jsonschema` is a thin wrapper around the upstream
# `check-jsonschema` tool plus a schema bundle. There's no
# spec-driven behavior to unit-test — the script's "spec" is "shell
# out to the validator with these inputs" — so it's intentionally
# excluded from the bidirectional rule.
#
# Honors SCRIPTS_DIR_OVERRIDE + TESTS_DIR_OVERRIDE for fixtures.
# Exits 0 on full coverage, 1 on any drift.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"

readonly DEFAULT_SCRIPTS_DIR="scripts"
readonly DEFAULT_TESTS_DIR="tests"
readonly SCRIPTS_DIR="${SCRIPTS_DIR_OVERRIDE:-${DEFAULT_SCRIPTS_DIR}}"
readonly TESTS_DIR="${TESTS_DIR_OVERRIDE:-${DEFAULT_TESTS_DIR}}"

# Script basenames (without `.sh`) that are intentionally not paired
# with a test. Keep this list short and justify each entry in the
# block comment above.
readonly EXEMPT=(
  "check-jsonschema"
)

is_exempt() {
  local -r name="$1"
  local e
  for e in "${EXEMPT[@]}"; do
    [[ ${name} == "${e}" ]] && return 0
  done
  return 1
}

failed=0
shopt -s nullglob

# Forward: every scripts/check-*.sh needs tests/<base>.test.sh
declare -a check_scripts=()
glob_into check_scripts 'check scripts' "${SCRIPTS_DIR}/check-*.sh"
for f in "${check_scripts[@]}"; do
  [[ -f ${f} ]] || continue
  base="$(basename "${f}" .sh)"
  if is_exempt "${base}"; then
    continue
  fi
  test_file="${TESTS_DIR}/${base}.test.sh"
  if [[ ! -f ${test_file} ]]; then
    printf '%s: missing matching test %s\n' "${f}" "${test_file}" >&2
    failed=$((failed + 1))
  fi
done

# Reverse: every tests/check-*.test.sh needs scripts/<base>.sh
declare -a check_harnesses=()
glob_into check_harnesses 'check-script test harnesses' "${TESTS_DIR}/check-*.test.sh"
for t in "${check_harnesses[@]}"; do
  [[ -f ${t} ]] || continue
  base="$(basename "${t}" .test.sh)"
  if is_exempt "${base}"; then
    continue
  fi
  script_file="${SCRIPTS_DIR}/${base}.sh"
  if [[ ! -f ${script_file} ]]; then
    printf '%s: missing matching script %s\n' "${t}" "${script_file}" >&2
    failed=$((failed + 1))
  fi
done

shopt -u nullglob

if ((failed > 0)); then
  printf '%d unpaired check script(s) or test(s)\n' "${failed}" >&2
  exit 1
fi
exit 0
