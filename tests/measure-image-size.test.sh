#!/usr/bin/env bash
# tests/measure-image-size.test.sh

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/measure-image-size.sh"
readonly FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/measure-image-size"

failures=0

function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

function pass() { printf 'PASS: %s\n' "$1"; }

# Scenario 1: happy path — build fixture, measure, assert JSON shape +
# positive integer values for both fields.
function scenario_happy_path() {
  local result
  result="$(mktemp -d)/result"
  nix build --no-link --print-out-paths \
    "${FIXTURE_DIR}#tiny-image" >"${result}.path"
  ln -s "$(cat "${result}.path")" "${result}"

  local json
  if ! json="$("${SCRIPT}" "${result}" "${FIXTURE_DIR}#tiny-image" 2>&1)"; then
    fail "happy path — script exited non-zero: ${json}"
    return
  fi

  if ! jq -e . >/dev/null 2>&1 <<<"${json}"; then
    fail "happy path — output is not valid JSON: ${json}"
    return
  fi

  local compressed closure
  compressed="$(jq -r '.compressed_bytes' <<<"${json}")"
  closure="$(jq -r '.closure_bytes' <<<"${json}")"

  if ! [[ ${compressed} =~ ^[0-9]+$ ]] || [[ ${compressed} -le 0 ]]; then
    fail "happy path — compressed_bytes not a positive int: ${compressed}"
    return
  fi
  if ! [[ ${closure} =~ ^[0-9]+$ ]] || [[ ${closure} -le 0 ]]; then
    fail "happy path — closure_bytes not a positive int: ${closure}"
    return
  fi

  pass "happy path (compressed=${compressed}, closure=${closure})"
}

# Scenario 2: missing result path — must exit non-zero with a useful
# stderr message naming the missing path.
function scenario_missing_result() {
  local stderr_file
  stderr_file="$(mktemp)"
  local exit_code=0
  "${SCRIPT}" /nonexistent/result /no/such#thing \
    >/dev/null 2>"${stderr_file}" || exit_code=$?

  if [[ ${exit_code} -eq 0 ]]; then
    fail "missing result — expected non-zero exit, got 0"
    cat -- "${stderr_file}" >&2
    rm -f -- "${stderr_file}"
    return
  fi
  if ! grep --fixed-strings --quiet -- "/nonexistent/result" \
    "${stderr_file}"; then
    fail "missing result — stderr missing the path"
    cat -- "${stderr_file}" >&2
    rm -f -- "${stderr_file}"
    return
  fi
  pass "missing result (exit ${exit_code})"
  rm -f -- "${stderr_file}"
}

# Scenario 3: JSON keys are exactly the two expected fields, nothing
# else. Locks the script's output contract.
function scenario_json_shape() {
  local result
  result="$(mktemp -d)/result"
  nix build --no-link --print-out-paths \
    "${FIXTURE_DIR}#tiny-image" >"${result}.path"
  ln -s "$(cat "${result}.path")" "${result}"

  local keys
  keys="$("${SCRIPT}" "${result}" "${FIXTURE_DIR}#tiny-image" |
    jq -r 'keys | sort | join(",")')"

  if [[ ${keys} != "closure_bytes,compressed_bytes" ]]; then
    fail "json shape — expected exact keys, got: ${keys}"
    return
  fi
  pass "json shape (keys=${keys})"
}

scenario_happy_path
scenario_missing_result
scenario_json_shape

if [[ ${failures} -ne 0 ]]; then
  printf '\n%d scenario(s) failed.\n' "${failures}" >&2
  exit 1
fi
printf '\nAll scenarios passed.\n'
