#!/usr/bin/env bash
# tests/classify-renovate-pr-author.test.sh
#
# Verdict + failure-mode matrix for
# scripts/classify-renovate-pr-author.sh. Pure classifier: one PR author
# login in, one canonical login out. Offline and deterministic.
#
# The accepted cases below are logins GitHub actually reports for the
# Renovate App, not spellings derived from its documentation. That
# distinction is what this harness protects: `gh pr view --json author`
# renders the App as `app/renovate`, and a matcher written from the
# `renovate[bot]` spelling alone rejects every real PR — silently, since
# an unrecognized author means the lock refresh simply does not run.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/classify-renovate-pr-author.sh"

failures=0

# @arg $1 description  @arg $2 expected stdout, or "<exit:N>" for a
#   non-zero exit whose exact code is the assertion
# remaining args: passed through to the classifier
function classify() {
  local -r desc="$1" want="$2"
  shift 2
  local got rc=0
  got="$(bash "${SCRIPT}" "$@" 2>/dev/null)" || rc=$?
  if [[ ${want} == "<exit:"* ]]; then
    local -r want_rc="${want#<exit:}"
    if [[ ${rc} -ne ${want_rc%>} ]]; then
      printf 'FAIL %s: exit %d, want %s\n' "${desc}" "${rc}" "${want}" >&2
      failures=1
      return
    fi
    printf 'OK   %s (exit %d)\n' "${desc}" "${rc}"
    return
  fi
  if [[ ${rc} -ne 0 ]]; then
    printf 'FAIL %s: exit %d, want %s\n' "${desc}" "${rc}" "${want}" >&2
    failures=1
    return
  fi
  if [[ ${got} != "${want}" ]]; then
    printf 'FAIL %s: got %q want %q\n' "${desc}" "${got}" "${want}" >&2
    failures=1
    return
  fi
  printf 'OK   %s\n' "${desc}"
}

# --- the login the live API actually returns -----------------------
# This is the reported defect: the identify job read `app/renovate` and
# classified every Renovate PR as somebody else's.
classify "gh --json author login" renovate 'app/renovate'
classify "REST/GraphQL bot login" renovate 'renovate[bot]'
classify "self-hosted bare login" renovate 'renovate'
classify "both affixes at once" renovate 'app/renovate[bot]'

# --- case insensitivity --------------------------------------------
classify "capitalized login maps" renovate 'Renovate'
classify "screaming login maps" renovate 'APP/RENOVATE[BOT]'

# --- the substring hazard ------------------------------------------
# The workflow this drives pushes commits to a PR branch, so accepting
# any login that merely CONTAINS `renovate` would hand that push to a
# claimable username. Asserted from both sides of the affix.
classify "a prefixed lookalike is not Renovate" "<exit:3>" 'not-renovate'
classify "a suffixed lookalike is not Renovate" "<exit:3>" 'renovate-bot'
classify "an embedded lookalike is not Renovate" "<exit:3>" 'my-renovate-fork'
classify "a doubled affix is not Renovate" "<exit:3>" 'app/app/renovate'

# --- some other author is a verdict, not a failure -----------------
# Exit 3 is what lets the caller report an unexpected author while
# still treating a broken invocation (exit 2) differently.
classify "another bot is not Renovate" "<exit:3>" 'dependabot[bot]'
classify "a human is not Renovate" "<exit:3>" 'rvenutolo'

# --- operational errors --------------------------------------------
classify "empty login is operational, not another author" "<exit:2>" ''
classify "no argument" "<exit:2>"
classify "too many arguments" "<exit:2>" 'a' 'b'

if [[ ${failures} -ne 0 ]]; then
  printf '\nclassify-renovate-pr-author: FAILURES\n' >&2
  exit 1
fi
printf '\nclassify-renovate-pr-author: all passed\n'
