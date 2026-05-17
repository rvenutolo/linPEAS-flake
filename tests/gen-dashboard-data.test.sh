#!/usr/bin/env bash
# Test harness for scripts/gen-dashboard-data.sh security-critical hard-fail
# branches.
#
# Each scenario runs the script with environment-variable overrides that
# inject malformed inputs into one of the three security checks:
#   1. pin.version regex (^[0-9]{8}-[0-9a-f]{7,40}$)
#   2. pin.url prefix
#      (https://github.com/peass-ng/PEASS-ng/releases/download/)
#   3. bundle URL prefix
#      (https://github.com/rvenutolo/linPEAS-flake/releases/download/)
#   4. required field non-empty / non-null (require_field)
#
# Each scenario asserts:
#   - exit code 1
#   - expected diagnostic substring on stderr
#   - no partial dashboard.yml was written (file does not appear; if a
#     pre-existing file is on disk, its mtime is unchanged)

set -Eeuo pipefail
IFS=$'\n\t'
trap 'printf "[%s] %-5s line %s (exit %s): %s\n" \
  "$(date "+%Y-%m-%dT%H:%M:%S%z")" ERROR "${LINENO}" "$?" "${BASH_COMMAND}" >&2' ERR

# Resolve repo paths from the worktree, not from PWD — the harness must work
# whether invoked from the repo root or from tests/.
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/gen-dashboard-data.sh"
readonly FIXTURES_DIR="${REPO_ROOT}/tests/fixtures/dashboard-data"
readonly OUT_FILE="${REPO_ROOT}/docs/_data/dashboard.yml"

fail_count=0
pass_count=0

# @description Snapshot the dashboard.yml output path before a scenario so we
# can detect partial writes. Writes the mtime to stdout, or 'ABSENT' if the
# file does not exist. We do not try to be clever about race conditions —
# the script is sequential and the test harness is sequential, so a stable
# mtime across the script invocation is a reliable signal.
# @noargs
# @stdout 'ABSENT' or the file's mtime in epoch seconds
function snapshot_out_file() {
  if [[ -e ${OUT_FILE} ]]; then
    stat --format='%Y' "${OUT_FILE}"
  else
    printf '%s\n' 'ABSENT'
  fi
}

# @description Assert that the dashboard.yml output state matches a prior
# snapshot. Fails the calling scenario if the file appeared (was 'ABSENT'),
# or if its mtime changed.
# @arg $1 prior snapshot value from snapshot_out_file
# @arg $2 scenario name (for the diagnostic message)
# @stdout nothing on success; failure prints to stderr and returns 1
function assert_out_file_unchanged() {
  local -r prior="$1"
  local -r scenario="$2"
  local current
  current="$(snapshot_out_file)"
  if [[ ${prior} == 'ABSENT' && ${current} != 'ABSENT' ]]; then
    printf 'FAIL: %s — partial dashboard.yml was written\n' "${scenario}" >&2
    return 1
  fi
  if [[ ${prior} != 'ABSENT' && ${prior} != "${current}" ]]; then
    printf 'FAIL: %s — dashboard.yml mtime changed (%s -> %s)\n' \
      "${scenario}" "${prior}" "${current}" >&2
    return 1
  fi
  return 0
}

# @description Run one failure scenario: invoke the script with the provided
# override env vars, capture stderr, then assert exit code, stderr
# substring, and that no partial output file was written.
# @arg $1 scenario name (printed on PASS/FAIL line)
# @arg $2 expected stderr substring
# @arg $@ remaining args: env-var assignments forwarded to the env command
function run_scenario() {
  local -r name="$1"
  local -r expected_msg="$2"
  shift 2
  local -a env_vars=("$@")

  local snapshot
  snapshot="$(snapshot_out_file)"

  local stderr_tmp
  stderr_tmp="$(mktemp)"
  # shellcheck disable=SC2064  # capture $stderr_tmp at trap-set time
  trap "rm --force -- '${stderr_tmp}'" RETURN

  local exit_code=0
  env "${env_vars[@]}" bash "${SCRIPT}" >/dev/null 2>"${stderr_tmp}" ||
    exit_code=$?

  if ((exit_code != 1)); then
    printf 'FAIL: %s — expected exit 1, got %d\n' "${name}" "${exit_code}" >&2
    printf '  stderr was:\n' >&2
    sed 's/^/    /' "${stderr_tmp}" >&2
    fail_count=$((fail_count + 1))
    return 0
  fi

  if ! grep --quiet --fixed-strings -- "${expected_msg}" "${stderr_tmp}"; then
    printf 'FAIL: %s — stderr missing expected substring %q\n' \
      "${name}" "${expected_msg}" >&2
    printf '  stderr was:\n' >&2
    sed 's/^/    /' "${stderr_tmp}" >&2
    fail_count=$((fail_count + 1))
    return 0
  fi

  if ! assert_out_file_unchanged "${snapshot}" "${name}"; then
    fail_count=$((fail_count + 1))
    return 0
  fi

  printf 'PASS: %s\n' "${name}"
  pass_count=$((pass_count + 1))
}

function main() {
  if [[ ! -f ${SCRIPT} ]]; then
    printf 'FAIL: script not found at %s\n' "${SCRIPT}" >&2
    exit 1
  fi
  if [[ ! -d ${FIXTURES_DIR} ]]; then
    printf 'FAIL: fixtures dir not found at %s\n' "${FIXTURES_DIR}" >&2
    exit 1
  fi

  # Scenario 1: bad pin.version regex. Pin URL is shaped correctly so only
  # the regex check trips; nothing else hard-fails first.
  run_scenario 'bad pin.version regex' \
    'pin.version does not match expected format' \
    "PIN_FILE_OVERRIDE=${FIXTURES_DIR}/bad-version-pin.json"

  # Scenario 2: bad pin.url prefix (NX-PD-2). Pin version is well-formed
  # so the regex check passes; the URL prefix check then trips.
  run_scenario 'bad pin.url prefix' \
    'pin.url outside expected upstream prefix' \
    "PIN_FILE_OVERRIDE=${FIXTURES_DIR}/bad-pin-url.json"

  # Scenario 3: missing required upstream field (tag_name). Pin is good so
  # we reach the upstream-release fetch and trip require_field on tag_name.
  run_scenario 'missing required field upstream_release.tag_name' \
    'required field missing: upstream_release.tag_name' \
    "PIN_FILE_OVERRIDE=${FIXTURES_DIR}/good-pin.json" \
    "UPSTREAM_RELEASE_JSON_OVERRIDE=${FIXTURES_DIR}/missing-tag-upstream-release.json"

  # Scenario 4: bundle URL outside expected prefix. Pin good, upstream good,
  # but this-repo latest-release advertises a non-github.com bundle URL.
  run_scenario 'bundle URL outside expected prefix' \
    'bundle URL outside expected prefix' \
    "PIN_FILE_OVERRIDE=${FIXTURES_DIR}/good-pin.json" \
    "UPSTREAM_RELEASE_JSON_OVERRIDE=${FIXTURES_DIR}/good-upstream-release.json" \
    "LATEST_RELEASE_JSON_OVERRIDE=${FIXTURES_DIR}/bad-bundle-url-latest-release.json"

  printf '\n%d passed, %d failed\n' "${pass_count}" "${fail_count}"
  if ((fail_count > 0)); then
    exit 1
  fi
  exit 0
}

main "$@"
