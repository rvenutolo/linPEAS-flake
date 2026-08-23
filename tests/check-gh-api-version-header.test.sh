#!/usr/bin/env bash
# tests/check-gh-api-version-header.test.sh
#
# Failure-mode harness for scripts/check-gh-api-version-header.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-gh-api-version-header.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-gh-api-version-header"

failures=0

# @arg $1 scenario name
# @arg $2 scan root to point SCRIPTS_DIR_OVERRIDE at
# @arg $3 expected exit
# @arg $4 expected stderr substring (empty skips)
# @arg $5 expected stdout substring (empty skips)
function run_scenario() {
  local -r name="$1"
  local -r scan_root="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"
  local -r expected_stdout="$5"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  SCRIPTS_DIR_OVERRIDE="${scan_root}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stdout} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stdout}" "${stdout_file}"; then
    printf 'FAIL: %s — stdout missing %q\n' "${name}" "${expected_stdout}" >&2
    printf 'stdout was:\n' >&2
    cat -- "${stdout_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  if [[ -n ${expected_stdout} ]]; then
    harness_assert_also "${expected_stdout}"
  fi
  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
}

function main() {
  # The clean path states its scope: how many call sites were held to the
  # header rule, and how many API mentions were set aside as comments. A
  # run that verified two live calls and a run that verified none because
  # every mention sat in a comment are the same verdict but very
  # different facts, and only the summary separates them.
  run_scenario 'gh api with explicit header passes' \
    "${FIXTURES}/good" 0 '' \
    'scanned 1 script(s); 2 API call site(s) carry an explicit header; 1 comment mention(s) skipped'
  run_scenario 'bare gh api fails' \
    "${FIXTURES}/bad-no-header" 1 'missing X-GitHub-Api-Version' ''
  run_scenario 'gh api on continuation lines fails' \
    "${FIXTURES}/bad-continuation" 1 'missing X-GitHub-Api-Version' ''
  run_scenario 'gh api in comments only passes' \
    "${FIXTURES}/good-comment-only" 0 '' \
    'scanned 1 script(s); 0 API call site(s) carry an explicit header; 3 comment mention(s) skipped'
  run_scenario 'api.github.com request without header fails' \
    "${FIXTURES}/bad-apigithub" 1 'missing X-GitHub-Api-Version' ''
  # The blind spot a text matcher cannot close: `gh` sits behind a `(`,
  # so no start-of-line or whitespace anchor reaches it. Most call sites
  # in the live tree are written this way.
  run_scenario 'gh api inside a command substitution fails' \
    "${FIXTURES}/bad-cmdsubst" 1 'missing X-GitHub-Api-Version' ''
  # The other direction of the same mistake: a diagnostic that names the
  # command it is reporting on is a string, and reporting it would push
  # every such message away from naming the command that failed.
  run_scenario 'gh api inside a diagnostic string passes' \
    "${FIXTURES}/good-string-mention" 0 '' \
    'scanned 1 script(s); 0 API call site(s) carry an explicit header; 1 comment mention(s) skipped'
  # A header the rule can only see by resolving the variable it arrives
  # in. Reading literal arguments alone reports a header that is there.
  run_scenario 'header supplied through a variable passes' \
    "${FIXTURES}/good-header-var" 0 '' \
    'scanned 1 script(s); 1 API call site(s) carry an explicit header; 2 comment mention(s) skipped'
  # An expansion for a command word names no command the parser can
  # resolve. The summary says so, naming the file, rather than scoring a
  # shape it never read.
  run_scenario 'unresolved command word is named, not scored' \
    "${FIXTURES}/good-unresolved" 0 '' \
    '1 unresolved command word(s) [unresolved-word.sh]'
  # A directory that is not there was never scanned, so it holds no
  # offenders: the could-not-run code, not a violation report.
  run_scenario 'missing scripts dir could not run' \
    "${FIXTURES}/does-not-exist" 2 'scripts dir not found' ''
  # A file the parser cannot read is source this run never saw, so it
  # takes the could-not-run code rather than being scored clean. The tree
  # is built here rather than committed: an unparsable `.sh` under tests/
  # is one treefmt cannot format, and the suite formats what it holds.
  local unparsable_root
  unparsable_root="$(mktemp --directory)"
  printf '#!/usr/bin/env bash\nif [[ -z\n' >"${unparsable_root}/broken.sh"
  run_scenario 'unparsable script could not run' \
    "${unparsable_root}" 2 'cannot parse' ''
  rm --recursive --force -- "${unparsable_root}"

  # Self-scan: the live scripts/ dir must lint clean. Guards against any
  # future script regressing on the X-GitHub-Api-Version header. The scan
  # root is what separates a run over the repo from a run over a fixture:
  # every other field on the summary line is a count both kinds of run can
  # print, and the counts here grow with the repo and are not asserted.
  # The live tree includes this checker itself — reading command words
  # from the parse tree means its own prose naming `gh api` is not an
  # invocation, so no file is skipped to keep the run green.
  local -r live_scope='scan root: scripts'
  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"
  local actual_exit=0
  "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  if ((actual_exit != 0)); then
    printf 'FAIL: live scripts/ has offenders:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- "${live_scope}" "${stdout_file}"; then
    printf 'FAIL: live scripts/ summary missing %q\n' "${live_scope}" >&2
    printf 'stdout was:\n' >&2
    cat -- "${stdout_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: live scripts/ clean\n'
  fi
  harness_assert_record 'live scripts/ self-scan' "${live_scope}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
