#!/usr/bin/env bash
# tests/check-exit-contract-documented.test.sh
#
# Behaviour harness for scripts/check-exit-contract-documented.sh.

set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-exit-contract-documented.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/exit-contract-documented"

failures=0

# @description Run the lint over one fixture scan root and assert its exit
#              code and, when given, a substring of its diagnostics.
# @arg $1 fixture directory name
# @arg $2 expected exit code
# @arg $3 substring expected in stderr (empty to skip)
function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(SCRIPTS_DIR_OVERRIDE="${FIXTURES}/${fixture}/scripts" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' \
      "${fixture}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    failures=$((failures + 1))
    return
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' \
      "${fixture}" "${want_msg}" "${got_stderr}" >&2
    failures=$((failures + 1))
    return
  fi
  printf 'OK   %s\n' "${fixture}"
}

# @description Assert the clean summary names the scope it walked, so a
#              pass states how much it read rather than only that it read
#              something.
# @arg $1 fixture directory name
# @arg $2 substring expected on stdout
function expect_summary() {
  local -r fixture="$1" want="$2"
  local got
  got="$(SCRIPTS_DIR_OVERRIDE="${FIXTURES}/${fixture}/scripts" "${SCRIPT}" 2>/dev/null)"
  if [[ ${got} != *"${want}"* ]]; then
    printf 'FAIL %s: summary missing %q\n  got: %s\n' "${fixture}" "${want}" "${got}" >&2
    failures=$((failures + 1))
    return
  fi
  printf 'OK   %s (summary)\n' "${fixture}"
}

# --- each documented contract shape the tree uses is accepted ---
expect good-dedicated 0 ''
expect good-list 0 ''
expect good-block 0 ''
# The clause sits past any fixed character window from its "Exits", so
# this is what pins the sentence — rather than a character budget — as
# the bound on the list form.
expect good-wrapped 0 ''

# --- a script that cannot reach exit 2 owes no exit-2 sentence ---
expect good-unreachable 0 ''
# A header line naming the code is documentation, not a code path; the
# comment strip is what keeps it from being read as one.
expect good-comment-only 0 ''

# --- both routes to exit 2 are found ---
expect bad-literal 1 'can reach exit 2 but its header documents no exit-2 case'
expect bad-helper 1 'can reach exit 2 but its header documents no exit-2 case'

# --- a 2 that is prose rather than an exit code excuses nothing ---
# 2FA and v2 open words; the token guard is what stops either from
# reading as a documented exit code.
expect bad-token-in-word 1 'check-i.sh'
# A standalone 2 in a later sentence is out of the contract sentence.
expect bad-late-sentence 1 'check-j.sh'

# --- a scan root with no script is a could-not-run, not a clean tree ---
expect empty 2 ''

# --- a clean run states its scope ---
expect_summary good-dedicated 'can reach exit 2'

if ((failures)); then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
