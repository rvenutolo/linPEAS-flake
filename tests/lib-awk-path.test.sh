#!/usr/bin/env bash
# @subject scripts/lib/awk-path.sh
# tests/lib-awk-path.test.sh — proves scripts/lib/awk-path.sh prefixes a
# relative path with `./` (including the hazard case where the first
# path component contains `=`, which `awk` would otherwise read as a
# variable assignment instead of a filename) and leaves an absolute path
# unchanged.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "${REPO_ROOT}/scripts/lib/awk-path.sh"

failures=0

function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# @description Call `awk_path`, record its stdout with the cross-scenario
# discrimination gate, and assert it equals the expected value exactly.
# @arg $1 scenario name  @arg $2 input path  @arg $3 expected output
function check() {
  local -r name="$1" input="$2" want="$3"
  local got out_file
  out_file="$(mktemp)"
  got="$(awk_path "${input}")"
  printf '%s' "${got}" >"${out_file}"
  harness_assert_record "${name}" "${got}" "${out_file}"

  if [[ ${got} == "${want}" ]]; then
    pass "${name}: awk_path(${input@Q}) == ${want@Q}"
  else
    fail "${name}: awk_path(${input@Q}) == ${got@Q}, want ${want@Q}"
  fi
  rm --force -- "${out_file}"
}

# 1. relative — a plain relative path gets `./`-prefixed.
check 'relative' 'sub/rel.txt' './sub/rel.txt'

# 2. absolute — an absolute path is returned unchanged; `./` ahead of it
# would resolve as a different (relative) path.
check 'absolute' '/abs/path.txt' '/abs/path.txt'

# 3. relative-with-equals — the hazard case the library exists for: a
# relative path whose first component contains `=` reads as an awk
# variable assignment unless prefixed.
check 'relative-with-equals' 'a=b/eq.txt' './a=b/eq.txt'

harness_assert_verify || failures=$((failures + 1))

if ((failures > 0)); then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
