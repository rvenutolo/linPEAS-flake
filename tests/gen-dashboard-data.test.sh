#!/usr/bin/env bash
# Test harness for scripts/gen-dashboard-data.sh security-critical hard-fail
# branches.
#
# Each scenario runs the script with environment-variable overrides that
# inject malformed inputs into one of the security checks:
#   1. pin.version regex (^[0-9]{8}-[0-9a-f]{7,40}$)
#   2. pin.url prefix
#      (https://github.com/peass-ng/PEASS-ng/releases/download/)
#   3. required field non-empty / non-null (require_field)
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
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
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
  harness_assert_record "${name}" "${expected_msg}" "${stderr_tmp}"

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

# @description Run the happy-path bump-lag scenario. Drives the script
# with all *_OVERRIDE inputs pointed at fixtures, writes the output to a
# temp file via OUT_FILE_OVERRIDE (so the real docs/_data/dashboard.yml is
# never touched), and asserts:
#   - exit code 0
#   - lag.recent length == 2 (the orphan release is skipped, not failed)
#   - skipped tag appears in stderr log
#   - lag_hours values match the expected timestamp arithmetic
# @noargs
function run_happy_lag_scenario() {
  local -r name='happy-path bump-lag pairing'
  local out_tmp stderr_tmp
  out_tmp="$(mktemp)"
  stderr_tmp="$(mktemp)"
  # shellcheck disable=SC2064  # capture paths at trap-set time
  trap "rm --force -- '${out_tmp}' '${stderr_tmp}'" RETURN

  local exit_code=0
  env \
    "PIN_FILE_OVERRIDE=${FIXTURES_DIR}/good-pin.json" \
    "UPSTREAM_RELEASE_JSON_OVERRIDE=${FIXTURES_DIR}/good-upstream-release.json" \
    "LATEST_RELEASE_JSON_OVERRIDE=${FIXTURES_DIR}/good-latest-release.json" \
    "THIS_REPO_RELEASES_JSON_OVERRIDE=${FIXTURES_DIR}/good-this-repo-releases.json" \
    "UPSTREAM_RELEASES_JSON_OVERRIDE=${FIXTURES_DIR}/good-upstream-releases.json" \
    "BUMP_PR_JSON_OVERRIDE=${FIXTURES_DIR}/good-bump-pr.json" \
    "PARITY_JSON_OVERRIDE=${FIXTURES_DIR}/good-parity.json" \
    "OUT_FILE_OVERRIDE=${out_tmp}" \
    bash "${SCRIPT}" >/dev/null 2>"${stderr_tmp}" || exit_code=$?
  harness_assert_record "${name}" \
    'lag: skipping this-repo release with no upstream match: 20240101-orphan0' \
    "${stderr_tmp}"

  if ((exit_code != 0)); then
    printf 'FAIL: %s — expected exit 0, got %d\n' "${name}" "${exit_code}" >&2
    printf '  stderr was:\n' >&2
    sed 's/^/    /' "${stderr_tmp}" >&2
    fail_count=$((fail_count + 1))
    return 0
  fi

  local recent_len
  recent_len="$(yq eval '.lag.recent | length' "${out_tmp}")"
  if [[ ${recent_len} != '2' ]]; then
    printf 'FAIL: %s — expected lag.recent length 2, got %s\n' "${name}" "${recent_len}" >&2
    fail_count=$((fail_count + 1))
    return 0
  fi

  if ! grep --quiet --fixed-strings -- \
    'lag: skipping this-repo release with no upstream match: 20240101-orphan0' \
    "${stderr_tmp}"; then
    printf 'FAIL: %s — stderr missing orphan-skip log line\n' "${name}" >&2
    printf '  stderr was:\n' >&2
    sed 's/^/    /' "${stderr_tmp}" >&2
    fail_count=$((fail_count + 1))
    return 0
  fi

  local lag_cd lag_5a
  lag_cd="$(yq eval '.lag.recent[] | select(.tag == "20260510-cd4bd619") | .lag_hours' "${out_tmp}")"
  lag_5a="$(yq eval '.lag.recent[] | select(.tag == "20260506-5a27482a") | .lag_hours' "${out_tmp}")"
  if [[ ${lag_cd} != '130.9' ]]; then
    printf 'FAIL: %s — expected lag 130.9 for cd4bd619, got %s\n' "${name}" "${lag_cd}" >&2
    fail_count=$((fail_count + 1))
    return 0
  fi
  if [[ ${lag_5a} != '48.6' ]]; then
    printf 'FAIL: %s — expected lag 48.6 for 5a27482a, got %s\n' "${name}" "${lag_5a}" >&2
    fail_count=$((fail_count + 1))
    return 0
  fi

  printf 'PASS: %s\n' "${name}"
  pass_count=$((pass_count + 1))
}

# @description Run the empty-bump-PR soft-fallback scenario. A transient
# Search-API failure yields an empty bump_pr_json (the fetch carries a
# trailing `|| true`). Per the script's hard-fail rule #2, a this-repo
# lookup failure must soft-fall-back to an empty section, not crash the
# build. Drives every other input from the happy fixtures and points
# BUMP_PR_JSON_OVERRIDE at an empty file, then asserts:
#   - exit code 0
#   - last_bump.pr_number == 0
#   - last_bump.pr_url == "" (empty)
#   - last_bump.merged_at == "" (empty)
#   - the output file was written
# @noargs
function run_empty_bump_pr_scenario() {
  local -r name='empty bump_pr_json soft-fallback'
  local out_tmp stderr_tmp empty_bump
  out_tmp="$(mktemp)"
  stderr_tmp="$(mktemp)"
  empty_bump="$(mktemp)"
  : >"${empty_bump}"
  # shellcheck disable=SC2064  # capture paths at trap-set time
  trap "rm --force -- '${out_tmp}' '${stderr_tmp}' '${empty_bump}'" RETURN

  local exit_code=0
  env \
    "PIN_FILE_OVERRIDE=${FIXTURES_DIR}/good-pin.json" \
    "UPSTREAM_RELEASE_JSON_OVERRIDE=${FIXTURES_DIR}/good-upstream-release.json" \
    "LATEST_RELEASE_JSON_OVERRIDE=${FIXTURES_DIR}/good-latest-release.json" \
    "THIS_REPO_RELEASES_JSON_OVERRIDE=${FIXTURES_DIR}/good-this-repo-releases.json" \
    "UPSTREAM_RELEASES_JSON_OVERRIDE=${FIXTURES_DIR}/good-upstream-releases.json" \
    "BUMP_PR_JSON_OVERRIDE=${empty_bump}" \
    "PARITY_JSON_OVERRIDE=${FIXTURES_DIR}/good-parity.json" \
    "OUT_FILE_OVERRIDE=${out_tmp}" \
    bash "${SCRIPT}" >/dev/null 2>"${stderr_tmp}" || exit_code=$?
  harness_assert_record "${name}" '' "${stderr_tmp}"

  if ((exit_code != 0)); then
    printf 'FAIL: %s — expected exit 0, got %d\n' "${name}" "${exit_code}" >&2
    printf '  stderr was:\n' >&2
    sed 's/^/    /' "${stderr_tmp}" >&2
    fail_count=$((fail_count + 1))
    return 0
  fi

  local pr_number pr_url merged_at
  pr_number="$(yq eval '.last_bump.pr_number' "${out_tmp}")"
  pr_url="$(yq eval '.last_bump.pr_url' "${out_tmp}")"
  merged_at="$(yq eval '.last_bump.merged_at' "${out_tmp}")"
  if [[ ${pr_number} != '0' ]]; then
    printf 'FAIL: %s — expected last_bump.pr_number 0, got %s\n' "${name}" "${pr_number}" >&2
    fail_count=$((fail_count + 1))
    return 0
  fi
  if [[ -n ${pr_url} && ${pr_url} != '""' ]]; then
    printf 'FAIL: %s — expected empty last_bump.pr_url, got %s\n' "${name}" "${pr_url}" >&2
    fail_count=$((fail_count + 1))
    return 0
  fi
  if [[ -n ${merged_at} && ${merged_at} != '""' ]]; then
    printf 'FAIL: %s — expected empty last_bump.merged_at, got %s\n' "${name}" "${merged_at}" >&2
    fail_count=$((fail_count + 1))
    return 0
  fi

  printf 'PASS: %s\n' "${name}"
  pass_count=$((pass_count + 1))
}

# @description Run an API-error soft-fallback scenario. `gh api` writes
# its JSON error body to stdout, so a failed this-repo lookup arrives as
# a non-empty non-null string. Per hard-fail rule #2 that must degrade to
# the documented empty/"unknown" section — never publish the error body's
# missing keys as data. Asserts exit 0, the documented fallback value, no
# literal null anywhere in the output, and a WARN naming the lookup.
# @arg $1 scenario name
# @arg $2 override var name to point at the 404 body
# @arg $3 yq path that must read back as the documented fallback
# @arg $4 expected fallback value at that path
# @arg $5 expected stderr substring (the WARN)
function run_api_error_scenario() {
  local -r name="$1"
  local -r override_var="$2"
  local -r yq_path="$3"
  local -r expected_value="$4"
  local -r expected_warn="$5"

  local out_tmp stderr_tmp
  out_tmp="$(mktemp)"
  stderr_tmp="$(mktemp)"
  # shellcheck disable=SC2064  # capture paths at trap-set time
  trap "rm --force -- '${out_tmp}' '${stderr_tmp}'" RETURN

  local -a env_vars=(
    "PIN_FILE_OVERRIDE=${FIXTURES_DIR}/good-pin.json"
    "UPSTREAM_RELEASE_JSON_OVERRIDE=${FIXTURES_DIR}/good-upstream-release.json"
    "LATEST_RELEASE_JSON_OVERRIDE=${FIXTURES_DIR}/good-latest-release.json"
    "THIS_REPO_RELEASES_JSON_OVERRIDE=${FIXTURES_DIR}/good-this-repo-releases.json"
    "UPSTREAM_RELEASES_JSON_OVERRIDE=${FIXTURES_DIR}/good-upstream-releases.json"
    "BUMP_PR_JSON_OVERRIDE=${FIXTURES_DIR}/good-bump-pr.json"
    "PARITY_JSON_OVERRIDE=${FIXTURES_DIR}/good-parity.json"
    "OUT_FILE_OVERRIDE=${out_tmp}"
    "${override_var}=${FIXTURES_DIR}/api-error-404.json"
  )

  local exit_code=0
  env "${env_vars[@]}" bash "${SCRIPT}" >/dev/null 2>"${stderr_tmp}" || exit_code=$?
  harness_assert_record "${name}" "${expected_warn}" "${stderr_tmp}"

  if ((exit_code != 0)); then
    printf 'FAIL: %s — expected exit 0, got %d\n' "${name}" "${exit_code}" >&2
    sed 's/^/    /' "${stderr_tmp}" >&2
    fail_count=$((fail_count + 1))
    return 0
  fi

  local actual
  actual="$(yq eval "${yq_path}" "${out_tmp}")"
  if [[ ${actual} != "${expected_value}" && ${actual} != '""' ]]; then
    printf 'FAIL: %s — expected %s == %q, got %q\n' \
      "${name}" "${yq_path}" "${expected_value}" "${actual}" >&2
    fail_count=$((fail_count + 1))
    return 0
  fi

  if grep --quiet 'null' "${out_tmp}"; then
    printf 'FAIL: %s — output contains a literal null\n' "${name}" >&2
    grep --line-number 'null' "${out_tmp}" >&2
    fail_count=$((fail_count + 1))
    return 0
  fi

  # Match on the WARN lines only: each lookup's label also appears in this
  # script's INFO progress lines, so the level filter keeps the assertion
  # pinned to a warning actually having been emitted.
  if ! grep --fixed-strings 'WARN' "${stderr_tmp}" |
    grep --fixed-strings --quiet -- "${expected_warn}"; then
    printf 'FAIL: %s — stderr missing WARN %q\n' "${name}" "${expected_warn}" >&2
    sed 's/^/    /' "${stderr_tmp}" >&2
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

  # Every scenario that gets as far as assembling the dashboard drives the
  # same this-repo/upstream release fixture pair, so all of them log the
  # orphan skip. The line separates a run that skips an unmatched release
  # from one that fails on it — the axis this assertion is about — but it
  # cannot separate the happy path from its soft-fallback siblings.
  harness_assert_exempt \
    'lag: skipping this-repo release with no upstream match: 20240101-orphan0' \
    '*' \
    'logged by every scenario driving the shared release fixture pair'

  # Scenario 1: bad pin.version regex. Pin URL is shaped correctly so only
  # the regex check trips; nothing else hard-fails first.
  run_scenario 'bad pin.version regex' \
    'pin.version does not match expected format' \
    "PIN_FILE_OVERRIDE=${FIXTURES_DIR}/bad-version-pin.json"

  # Scenario 2: bad pin.url prefix. Pin version is well-formed
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

  # Scenario 4: happy-path bump-lag pairing. Two of three this-repo releases
  # match upstream entries; the third is older than the upstream window and
  # must be skipped with a warning, not failed.
  run_happy_lag_scenario

  # Scenario 5: empty bump_pr_json soft-fallback. A transient last-bump-PR
  # Search-API failure must degrade to an empty last-bump section (exit 0),
  # per hard-fail rule #2, not crash the whole generator.
  run_empty_bump_pr_scenario

  # Scenario 6: this-repo releases/latest returns an API error body. It
  # must degrade to the documented empty release section, never publish a
  # literal "null" tag or a ":null" image ref.
  # The expected WARN names the degraded lookup *and* the reason: the
  # lookup label on its own is printed by the INFO progress line of every
  # scenario, including the ones where that lookup succeeded.
  run_api_error_scenario 'latest-release API error soft-fallback' \
    'LATEST_RELEASE_JSON_OVERRIDE' '.release.latest_tag' '' \
    'releases/latest: response is not valid JSON of the expected shape'

  # Scenario 7: last-bump-PR search returns an API error body.
  run_api_error_scenario 'bump-PR API error soft-fallback' \
    'BUMP_PR_JSON_OVERRIDE' '.last_bump.pr_number' '0' \
    'last bump PR: response is not valid JSON of the expected shape'

  # Scenario 8: verify-latest-release run lookup returns an API error body.
  run_api_error_scenario 'parity-run API error soft-fallback' \
    'PARITY_JSON_OVERRIDE' '.parity.conclusion' 'unknown' \
    'parity run: response is not valid JSON of the expected shape'

  harness_assert_verify || fail_count=$((fail_count + 1))

  printf '\n%d passed, %d failed\n' "${pass_count}" "${fail_count}"
  if ((fail_count > 0)); then
    exit 1
  fi
  exit 0
}

main "$@"
