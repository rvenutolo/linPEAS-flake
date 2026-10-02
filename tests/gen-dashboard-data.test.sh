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
#   - exit code 1 for a rejected input, 2 when the script could not run
#     at all (a missing input artifact or tool)
#   - expected diagnostic substring on stderr
#   - nothing was written where the output could land: see
#     "Confinement" below
#
# Confinement. Each failure scenario runs in a directory of its own:
# the script's cwd is an empty `git init` sandbox there, so even its
# default output path resolves inside the sandbox, and OUT_FILE_OVERRIDE
# points at `out/dashboard.yml` beside it, with `out/` absent beforehand.
# After the run the scenario fails if anything but a directory sits
# under `out/` (a partial dashboard.yml or a stray temp file) or if the
# sandbox holds a `docs/` directory, which the script creates only when
# it is aiming at its default path instead of the override. Directories
# under `out/` are allowed: the script creates the output directory once
# the pin is read.
# A last check compares every `docs/_data/dashboard.yml*` entry of the
# real tree (inode, size, nanosecond mtime and ctime, SHA-256), and
# whether `docs/_data/` is a directory, before and after the run; it is the only
# check that sees a scenario aimed at the real path, and it reads nothing
# but those entries. Writes anywhere else, such as TMPDIR or the sandbox
# outside `docs/`, are not checked.
#
# Git finds the sandbox only if the caller's environment does not name a
# repository for it: a hook running in a linked worktree exports GIT_DIR,
# which would point both the sandbox's `git init` and the script's root
# lookup at the real repository. Every variable `git rev-parse
# --local-env-vars` lists is unset for both.
#
# Each scenario sets an *_OVERRIDE for every lookup the script reaches
# before its asserted outcome, except the one scenario that exercises a
# failing `gh`, which puts its own shim first on PATH instead. Behind
# both sits a tripwire `gh` for the whole run, and the run fails on any
# call it logged. A `gh` call reaches it from any scenario where it is
# the first `gh` on PATH: every scenario but the failing-`gh` one.
#
# A required lookup that escapes its override exits 2 with "could not
# fetch …", which the scenario's own exit or stderr assertion already
# fails on. A soft lookup that escapes absorbs the tripwire's exit 97 as
# a degraded lookup, logs a WARN and leaves the scenario's verdict
# unchanged, so only the log check catches it. The log check also
# catches the failing-`gh` scenario losing its shim, since the exit 2
# the tripwire then causes is that scenario's expected outcome.
#
# Where another `gh` comes first on PATH, nothing in the automated run
# catches a soft lookup that escapes: in the failing-`gh` scenario its
# shim answers the call, and a scenario that builds a PATH finding a
# real `gh` first reaches the network. The harness passes with the
# network blocked, checked by hand with
# `unshare --user --map-current-user --net`; under that block an
# escaping soft lookup degrades the same way, so the block alone does
# not catch it either.

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
# shellcheck source=scripts/lib/enumerate.sh
source "${REPO_ROOT}/scripts/lib/enumerate.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/gen-dashboard-data.sh"
readonly FIXTURES_DIR="${REPO_ROOT}/tests/fixtures/dashboard-data"
readonly REAL_OUT_DIR="${REPO_ROOT}/docs/_data"

git_local_vars="$(git rev-parse --local-env-vars)"
if [[ -z ${git_local_vars} ]]; then
  printf 'FAIL: git rev-parse --local-env-vars listed no variables\n' >&2
  exit 2
fi
mapfile -t git_local_var_list <<<"${git_local_vars}"
git_unset_args=()
for git_local_var in "${git_local_var_list[@]}"; do
  git_unset_args+=(-u "${git_local_var}")
done
readonly -a GIT_UNSET_ARGS=("${git_unset_args[@]}")

fail_count=0
pass_count=0

tripwire_dir="$(mktemp --directory)"
readonly TRIPWIRE_DIR="${tripwire_dir}"
readonly TRIPWIRE_LOG="${TRIPWIRE_DIR}/calls.log"
runtime_dir="$(mktemp --directory)"
readonly RUNTIME_DIR="${runtime_dir}"
trap 'rm --recursive --force -- "${TRIPWIRE_DIR}" "${RUNTIME_DIR}"' EXIT

# @description Install the tripwire `gh` ahead of the real one on PATH.
# `run_failing_gh_scenario` prepends its shim to this PATH, so the shim
# still wins there; any other scenario that inherits PATH and calls `gh`
# reaches this one. The log path is baked into the tripwire so a
# scenario that rewrites other variables cannot lose it.
# @noargs
function install_gh_tripwire() {
  : >"${TRIPWIRE_LOG}"
  printf '#!/usr/bin/env bash\nlog=%q\n' "${TRIPWIRE_LOG}" >"${TRIPWIRE_DIR}/gh"
  cat >>"${TRIPWIRE_DIR}/gh" <<'TRIPWIRE'
printf '%s\n' "$*" >>"${log}"
printf 'gh called outside the overrides: %s\n' "$*" >&2
exit 97
TRIPWIRE
  chmod +x -- "${TRIPWIRE_DIR}/gh"
  PATH="${TRIPWIRE_DIR}:${PATH}"
}

# @description Fail the run when any scenario reached the tripwire,
# naming each call.
# @noargs
function check_gh_tripwire() {
  if [[ -s ${TRIPWIRE_LOG} ]]; then
    printf 'FAIL: a scenario called gh outside the overrides; calls that reached the tripwire:\n' >&2
    sed 's/^/  gh /' -- "${TRIPWIRE_LOG}" >&2
    fail_count=$((fail_count + 1))
  fi
}

# @description Print one line per `dashboard.yml*` entry in the real
# docs/_data/ (inode, size, nanosecond mtime and ctime, SHA-256), or one
# line saying it is not a directory. The entries are listed by `find -H
# -name`, not by a glob, so a repository path holding glob characters
# cannot turn the pattern into one that matches nothing, and `-H` follows
# a docs/_data/ that is a symlink. A scenario aimed at the real path that replaces the file changes the
# inode, one that rewrites it in place changes the timestamps even with
# the same bytes, and a temp file left beside it adds a line. Prints
# nothing when no such entry exists.
# @noargs
# @stdout one line per entry
function snapshot_real_out() {
  if [[ ! -d ${REAL_OUT_DIR} ]]; then
    printf '%s is not a directory\n' "${REAL_OUT_DIR}"
    return 0
  fi
  # No entry is a valid state: the file is gitignored, so a fresh clone
  # or a CI checkout has none.
  local LINT_ALLOW_EMPTY_SCAN=1
  local -a entries=()
  enumerate_into entries 'find over the real docs/_data/' \
    find -H "${REAL_OUT_DIR}" -mindepth 1 -maxdepth 1 -name 'dashboard.yml*' -print0
  local entry digest
  for entry in "${entries[@]}"; do
    # Only a readable regular file has a digest; any other entry is
    # compared on its stat fields alone.
    digest='-'
    if [[ -f ${entry} && -r ${entry} ]]; then
      digest="$(sha256sum -- "${entry}" | cut --delimiter=' ' --fields=1)"
    fi
    printf '%s %s\n' \
      "$(stat --format='%n %i %s %.9Y %.9Z' -- "${entry}")" "${digest}"
  done
}

# @description Make a scenario directory holding an empty `git init`
# sandbox, the script's cwd, and print its path. `out/`, the override's
# parent, is left absent. The global and system git config are kept out so
# a runner's config cannot change how git resolves the sandbox, and the
# caller's repository variables are unset (see the header).
# @noargs
# @stdout the scenario directory
function make_scenario_dir() {
  local dir
  dir="$(mktemp --directory)"
  env "${GIT_UNSET_ARGS[@]}" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git init --quiet -- "${dir}/sandbox"
  printf '%s\n' "${dir}"
}

# @description Run the script confined to a scenario directory: cwd in
# its sandbox, OUT_FILE_OVERRIDE at its `out/dashboard.yml`.
# @arg $1 scenario directory from make_scenario_dir
# @arg $2 stdout capture file
# @arg $3 stderr capture file
# @arg $@ remaining args: env-var assignments forwarded to the env command
# @exitcode the script's exit code
function run_confined() {
  local -r dir="$1"
  local -r stdout_file="$2"
  local -r stderr_file="$3"
  shift 3
  (
    cd -- "${dir}/sandbox"
    env "${GIT_UNSET_ARGS[@]}" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$@" \
      "OUT_FILE_OVERRIDE=${dir}/out/dashboard.yml" \
      bash "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}"
  )
}

# @description Assert a confined run wrote nothing: nothing but
# directories under `out/`, no `docs/` in the sandbox, and the real
# `dashboard.yml*` entries as they were before the run.
# @arg $1 scenario directory from make_scenario_dir
# @arg $2 snapshot_real_out output taken before the run
# @arg $3 scenario name (for the diagnostic message)
# @stdout nothing on success; failure prints to stderr and returns 1
function assert_confined() {
  local -r dir="$1"
  local -r prior="$2"
  local -r scenario="$3"
  # Finding nothing is the expected outcome here, not an empty scan.
  local LINT_ALLOW_EMPTY_SCAN=1
  local -a written=()
  if [[ -e ${dir}/out ]]; then
    enumerate_into written 'find over the override directory' \
      find "${dir}/out" ! -type d -print0
  fi
  if ((${#written[@]} > 0)); then
    printf 'FAIL: %s — a failing run wrote under the override directory:\n' "${scenario}" >&2
    printf '  %s\n' "${written[@]}" >&2
    return 1
  fi
  if [[ -e ${dir}/sandbox/docs ]]; then
    printf 'FAIL: %s — the script aimed at its default path, not OUT_FILE_OVERRIDE (sandbox docs/ created)\n' \
      "${scenario}" >&2
    return 1
  fi
  local current
  current="$(snapshot_real_out)"
  if [[ ${current} != "${prior}" ]]; then
    printf 'FAIL: %s — the real docs/_data/dashboard.yml* entries changed\n' "${scenario}" >&2
    printf '  before: %s\n  after:  %s\n' "${prior:-<none>}" "${current:-<none>}" >&2
    return 1
  fi
  return 0
}

# @description Run one failure scenario: invoke the script confined to a
# scenario directory with the provided override env vars, capture stderr,
# then assert exit code, stderr substring, and that nothing was written.
# @arg $1 scenario name (printed on PASS/FAIL line)
# @arg $2 expected stderr substring
# @arg $3 expected exit code — 1 for a rejected input, 2 when the script
#         could not run at all (missing input artifact or tool)
# @arg $@ remaining args: env-var assignments forwarded to the env command
function run_scenario() {
  local -r name="$1"
  local -r expected_msg="$2"
  local -r want_exit="$3"
  shift 3
  local -a env_vars=("$@")

  local snapshot
  snapshot="$(snapshot_real_out)"

  local scenario_dir stderr_tmp stdout_tmp outcome_tmp
  scenario_dir="$(make_scenario_dir)"
  stderr_tmp="$(mktemp)"
  stdout_tmp="$(mktemp)"
  outcome_tmp="$(mktemp)"
  # shellcheck disable=SC2064  # capture the paths at trap-set time
  trap "rm --recursive --force -- '${scenario_dir}' '${stderr_tmp}' '${stdout_tmp}' '${outcome_tmp}'" RETURN

  local exit_code=0
  run_confined "${scenario_dir}" "${stdout_tmp}" "${stderr_tmp}" "${env_vars[@]}" ||
    exit_code=$?
  printf 'harness-assert-outcome: exit=%d\n' "${exit_code}" >"${outcome_tmp}"
  harness_assert_record "${name}" "${expected_msg}" \
    "${outcome_tmp}" "${stdout_tmp}" "${stderr_tmp}"

  if ((exit_code != want_exit)); then
    printf 'FAIL: %s — expected exit %d, got %d\n' "${name}" "${want_exit}" "${exit_code}" >&2
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

  if ! assert_confined "${scenario_dir}" "${snapshot}" "${name}"; then
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
# The release fixture pair is this scenario's own, carrying an orphan tag
# no other fixture uses, so the orphan-skip line asserted here belongs to
# this scenario rather than to every scenario that assembles a dashboard.
# @noargs
function run_happy_lag_scenario() {
  local -r name='happy-path bump-lag pairing'
  local out_tmp stderr_tmp stdout_tmp outcome_tmp
  out_tmp="$(mktemp)"
  stderr_tmp="$(mktemp)"
  stdout_tmp="$(mktemp)"
  outcome_tmp="$(mktemp)"
  # shellcheck disable=SC2064  # capture paths at trap-set time
  trap "rm --force -- '${out_tmp}' '${stderr_tmp}' '${stdout_tmp}' '${outcome_tmp}'" RETURN

  local exit_code=0
  env \
    "PIN_FILE_OVERRIDE=${FIXTURES_DIR}/good-pin.json" \
    "UPSTREAM_RELEASE_JSON_OVERRIDE=${FIXTURES_DIR}/good-upstream-release.json" \
    "LATEST_RELEASE_JSON_OVERRIDE=${FIXTURES_DIR}/good-latest-release.json" \
    "THIS_REPO_RELEASES_JSON_OVERRIDE=${FIXTURES_DIR}/happy-lag-this-repo-releases.json" \
    "UPSTREAM_RELEASES_JSON_OVERRIDE=${FIXTURES_DIR}/happy-lag-upstream-releases.json" \
    "BUMP_PR_JSON_OVERRIDE=${FIXTURES_DIR}/good-bump-pr.json" \
    "PARITY_JSON_OVERRIDE=${FIXTURES_DIR}/good-parity.json" \
    "OUT_FILE_OVERRIDE=${out_tmp}" \
    bash "${SCRIPT}" >"${stdout_tmp}" 2>"${stderr_tmp}" || exit_code=$?
  printf 'harness-assert-outcome: exit=%d\n' "${exit_code}" >"${outcome_tmp}"
  harness_assert_record "${name}" \
    'lag: skipping this-repo release with no upstream match: 20240101-lagorphan' \
    "${outcome_tmp}" "${stdout_tmp}" "${stderr_tmp}"

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
    'lag: skipping this-repo release with no upstream match: 20240101-lagorphan' \
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
# trailing `|| true`). Per the script's hard-fail rule 2, a this-repo
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
  local out_tmp stderr_tmp stdout_tmp outcome_tmp empty_bump
  out_tmp="$(mktemp)"
  stderr_tmp="$(mktemp)"
  stdout_tmp="$(mktemp)"
  outcome_tmp="$(mktemp)"
  empty_bump="$(mktemp)"
  : >"${empty_bump}"
  # shellcheck disable=SC2064  # capture paths at trap-set time
  trap "rm --force -- '${out_tmp}' '${stderr_tmp}' '${stdout_tmp}' '${outcome_tmp}' '${empty_bump}'" RETURN

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
    bash "${SCRIPT}" >"${stdout_tmp}" 2>"${stderr_tmp}" || exit_code=$?
  printf 'harness-assert-outcome: exit=%d\n' "${exit_code}" >"${outcome_tmp}"
  harness_assert_record "${name}" '' \
    "${outcome_tmp}" "${stdout_tmp}" "${stderr_tmp}"

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

# @description Run the generator with a `gh` shim that is present and
# fails, and no override for the required upstream-release lookup, so the
# fetch itself is the fault. Asserts exit 2 — the lookup never happened,
# so it says nothing about the pin — and that no dashboard.yml was
# written.
# @arg $1 scenario name  @arg $2 expected stderr substring
function run_failing_gh_scenario() {
  local -r name="$1"
  local -r expected_stderr="$2"

  local shim_dir scenario_dir stderr_tmp stdout_tmp outcome_tmp
  shim_dir="$(mktemp --directory)"
  printf '#!/usr/bin/env bash\nexit 1\n' >"${shim_dir}/gh"
  chmod +x -- "${shim_dir}/gh"
  scenario_dir="$(make_scenario_dir)"
  stderr_tmp="$(mktemp)"
  stdout_tmp="$(mktemp)"
  outcome_tmp="$(mktemp)"
  # shellcheck disable=SC2064  # capture paths at trap-set time
  trap "rm --force --recursive -- '${shim_dir}' '${scenario_dir}' '${stderr_tmp}' '${stdout_tmp}' '${outcome_tmp}'" RETURN

  local prior
  prior="$(snapshot_real_out)"

  local exit_code=0
  run_confined "${scenario_dir}" "${stdout_tmp}" "${stderr_tmp}" \
    "PATH=${shim_dir}:${PATH}" \
    "PIN_FILE_OVERRIDE=${FIXTURES_DIR}/good-pin.json" || exit_code=$?
  printf 'harness-assert-outcome: exit=%d\n' "${exit_code}" >"${outcome_tmp}"
  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_tmp}" "${stdout_tmp}" "${stderr_tmp}"

  if ((exit_code != 2)); then
    printf 'FAIL: %s — expected exit 2, got %d\n' "${name}" "${exit_code}" >&2
    sed 's/^/    /' "${stderr_tmp}" >&2
    fail_count=$((fail_count + 1))
    return 0
  fi
  if ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_tmp}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    sed 's/^/    /' "${stderr_tmp}" >&2
    fail_count=$((fail_count + 1))
    return 0
  fi
  if ! assert_confined "${scenario_dir}" "${prior}" "${name}"; then
    fail_count=$((fail_count + 1))
    return 0
  fi
  printf 'PASS: %s\n' "${name}"
  pass_count=$((pass_count + 1))
}

# @description Run an API-error soft-fallback scenario. `gh api` writes
# its JSON error body to stdout, so a failed this-repo lookup arrives as
# a non-empty non-null string. Per hard-fail rule 2 that must degrade to
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

  local out_tmp stderr_tmp stdout_tmp outcome_tmp
  out_tmp="$(mktemp)"
  stderr_tmp="$(mktemp)"
  stdout_tmp="$(mktemp)"
  outcome_tmp="$(mktemp)"
  # shellcheck disable=SC2064  # capture paths at trap-set time
  trap "rm --force -- '${out_tmp}' '${stderr_tmp}' '${stdout_tmp}' '${outcome_tmp}'" RETURN

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
  env "${env_vars[@]}" bash "${SCRIPT}" >"${stdout_tmp}" 2>"${stderr_tmp}" || exit_code=$?
  printf 'harness-assert-outcome: exit=%d\n' "${exit_code}" >"${outcome_tmp}"
  harness_assert_record "${name}" "${expected_warn}" \
    "${outcome_tmp}" "${stdout_tmp}" "${stderr_tmp}"

  if ((exit_code != 0)); then
    printf 'FAIL: %s — expected exit 0, got %d\n' "${name}" "${exit_code}" >&2
    sed 's/^/    /' "${stderr_tmp}" >&2
    fail_count=$((fail_count + 1))
    return 0
  fi

  local actual
  actual="$(yq eval "${yq_path}" "${out_tmp}")"
  if [[ ${actual} != "${expected_value}" ]]; then
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

  install_gh_tripwire

  # Scenario 1: bad pin.version regex. Pin URL is shaped correctly so only
  # the regex check trips; nothing else hard-fails first.
  run_scenario 'bad pin.version regex' \
    'pin.version does not match expected format' 1 \
    "PIN_FILE_OVERRIDE=${FIXTURES_DIR}/bad-version-pin.json"

  # Scenario 2: bad pin.url prefix. Pin version is well-formed
  # so the regex check passes; the URL prefix check then trips.
  run_scenario 'bad pin.url prefix' \
    'pin.url outside expected upstream prefix' 1 \
    "PIN_FILE_OVERRIDE=${FIXTURES_DIR}/bad-pin-url.json"

  # Scenario 3: missing required upstream field (tag_name). Pin is good so
  # we reach the upstream-release fetch. A GitHub release object always
  # carries tag_name, so its absence is a payload-shape fault:
  # require_json_payload catches it before require_field ever runs, which
  # is what closes the substantive-drift misreport a bare require_field
  # check on an unguarded read would otherwise produce (exit 1, "required
  # field missing", indistinguishable from a real posture change).
  run_scenario 'missing upstream_release.tag_name is a tooling error' \
    'dashboard upstream release: unexpected payload shape from UPSTREAM_RELEASE_JSON_OVERRIDE: .tag_name is null, want string' 2 \
    "PIN_FILE_OVERRIDE=${FIXTURES_DIR}/good-pin.json" \
    "UPSTREAM_RELEASE_JSON_OVERRIDE=${FIXTURES_DIR}/missing-tag-upstream-release.json"

  # Scenario 3b: the pin file itself is absent. The script never runs, so
  # this is exit 2 (fix the environment) rather than a rejected input.
  # The source is named by kind (the override variable), never by the
  # fixture path that names the scenario.
  #
  # The `dashboard pin` / `dashboard upstream release` subject prefixes
  # asserted here and above are load-bearing, not decoration. Both source
  # kinds are shared with `bump-linpeas.sh`, which reads the same pin
  # file and names the same upstream-release route, so the source alone
  # cannot tell an operator which script could not read its payload.
  # Only the prefix does, and nothing in a per-harness discrimination
  # gate can see a collision that lives in another file.
  run_scenario 'absent pin file cannot be read' \
    'dashboard pin: payload from PIN_FILE_OVERRIDE not found' 2 \
    "PIN_FILE_OVERRIDE=${FIXTURES_DIR}/linpeas-pin-absent.json"

  # Scenario 3f-h: the same could-not-run treatment for the three
  # override-or-live fetches gated by require_json_payload. Each keeps
  # every override before it valid so the run reaches that fetch, the
  # soft this-repo releases/latest lookup included, and points only the
  # override under test at an absent path.
  run_scenario 'absent upstream-release payload is a tooling error' \
    'dashboard upstream release: payload from UPSTREAM_RELEASE_JSON_OVERRIDE not found' 2 \
    "PIN_FILE_OVERRIDE=${FIXTURES_DIR}/good-pin.json" \
    "UPSTREAM_RELEASE_JSON_OVERRIDE=${FIXTURES_DIR}/upstream-release-absent.json"
  run_scenario 'absent this-repo-releases payload is a tooling error' \
    'payload from THIS_REPO_RELEASES_JSON_OVERRIDE not found' 2 \
    "PIN_FILE_OVERRIDE=${FIXTURES_DIR}/good-pin.json" \
    "UPSTREAM_RELEASE_JSON_OVERRIDE=${FIXTURES_DIR}/good-upstream-release.json" \
    "LATEST_RELEASE_JSON_OVERRIDE=${FIXTURES_DIR}/good-latest-release.json" \
    "THIS_REPO_RELEASES_JSON_OVERRIDE=${FIXTURES_DIR}/this-repo-releases-absent.json"
  run_scenario 'absent upstream-releases payload is a tooling error' \
    'payload from UPSTREAM_RELEASES_JSON_OVERRIDE not found' 2 \
    "PIN_FILE_OVERRIDE=${FIXTURES_DIR}/good-pin.json" \
    "UPSTREAM_RELEASE_JSON_OVERRIDE=${FIXTURES_DIR}/good-upstream-release.json" \
    "LATEST_RELEASE_JSON_OVERRIDE=${FIXTURES_DIR}/good-latest-release.json" \
    "THIS_REPO_RELEASES_JSON_OVERRIDE=${FIXTURES_DIR}/good-this-repo-releases.json" \
    "UPSTREAM_RELEASES_JSON_OVERRIDE=${FIXTURES_DIR}/upstream-releases-absent.json"

  # Scenario 3c-e: a malformed pin payload is a could-not-run, not the raw
  # `jq` crash an unguarded read of it would produce and not the
  # require_field drift path. Reuses PIN_FILE_OVERRIDE (scenarios 1-3
  # above already prove it selects the pin source); each fixture trips a
  # different require_json_payload diagnostic so the three scenarios stay
  # distinct.
  run_scenario 'empty pin payload is a tooling error' \
    'dashboard pin: empty payload from PIN_FILE_OVERRIDE' 2 \
    "PIN_FILE_OVERRIDE=${FIXTURES_DIR}/bad-pin-empty.json"
  run_scenario 'pin payload that is not JSON is a tooling error' \
    'dashboard pin: payload from PIN_FILE_OVERRIDE is not valid JSON' 2 \
    "PIN_FILE_OVERRIDE=${FIXTURES_DIR}/bad-pin-not-json.txt"
  run_scenario 'boolean-typed pin payload is a tooling error' \
    'dashboard pin: unexpected payload shape from PIN_FILE_OVERRIDE: payload is boolean, want object' 2 \
    "PIN_FILE_OVERRIDE=${FIXTURES_DIR}/bad-pin-wrong-type.json"

  # Scenario 3i: a failure after the temp file exists. The payload gate
  # proves each `published_at` is a string, not a date, so one that
  # `fromdateiso8601` cannot parse fails the lag pairing, which runs after
  # make_temp has created the temp file. That file must not outlive the
  # run. The fixture is built here rather than checked in, from the good
  # releases list.
  local bad_date_releases="${RUNTIME_DIR}/bad-date-this-repo-releases.json"
  jq '.[0].published_at = "not-a-date"' \
    "${FIXTURES_DIR}/good-this-repo-releases.json" >"${bad_date_releases}"
  run_scenario 'unparsable release date after the temp file is a tooling error' \
    'could not pair this-repo releases with upstream releases for bump lag' 2 \
    "PIN_FILE_OVERRIDE=${FIXTURES_DIR}/good-pin.json" \
    "UPSTREAM_RELEASE_JSON_OVERRIDE=${FIXTURES_DIR}/good-upstream-release.json" \
    "LATEST_RELEASE_JSON_OVERRIDE=${FIXTURES_DIR}/good-latest-release.json" \
    "THIS_REPO_RELEASES_JSON_OVERRIDE=${bad_date_releases}" \
    "UPSTREAM_RELEASES_JSON_OVERRIDE=${FIXTURES_DIR}/good-upstream-releases.json" \
    "BUMP_PR_JSON_OVERRIDE=${FIXTURES_DIR}/good-bump-pr.json" \
    "PARITY_JSON_OVERRIDE=${FIXTURES_DIR}/good-parity.json"

  # Scenario 4: happy-path bump-lag pairing. Two of three this-repo releases
  # match upstream entries; the third is older than the upstream window and
  # must be skipped with a warning, not failed.
  run_happy_lag_scenario

  # Scenario 5: empty bump_pr_json soft-fallback. A transient last-bump-PR
  # Search-API failure must degrade to an empty last-bump section (exit 0),
  # per hard-fail rule 2, not crash the whole generator.
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

  # A `gh` that is present and fails is a lookup that never happened, not
  # upstream data the generator read and rejected.
  run_failing_gh_scenario 'failing gh on the required upstream lookup is a tooling error' \
    'could not fetch repos/peass-ng/PEASS-ng/releases/latest'

  harness_assert_verify || fail_count=$((fail_count + 1))
  check_gh_tripwire

  printf '\n%d passed, %d failed\n' "${pass_count}" "${fail_count}"
  if ((fail_count > 0)); then
    exit 1
  fi
  exit 0
}

main "$@"
