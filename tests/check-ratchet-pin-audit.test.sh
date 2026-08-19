#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-ratchet-pin-audit.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/ratchet-pin-audit"

function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(WORKFLOW_PATH_OVERRIDE="${FIXTURES}/${fixture}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' \
      "${fixture}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' \
      "${fixture}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${fixture}"
}

expect good.yml 0 ""
expect bad-missing-permissions.yml 1 "top-level permissions must be {}"
expect bad-missing-concurrency.yml 1 "concurrency.group must be"
expect bad-missing-reason.yml 1 "notify body missing reason token"
expect bad-missing-dispatch.yml 1 "on: must include workflow_dispatch"
expect bad-hardenrunner-first.yml 1 "first step must be step-security/harden-runner"
expect bad-job-permissions.yml 1 "permissions must be exactly { contents: read }"
expect bad-persist-credentials.yml 1 "set persist-credentials: false"
expect bad-job-timeout.yml 1 "timeout-minutes missing"
expect bad-schedule.yml 1 "on: must include a schedule sequence"
# An absent workflow file is a missing input: no invariant was read, so
# it must not be counted as a failed one.
expect no-such-workflow.yml 2 "workflow not found at"

# --- documented ratchet version vs the installed tool ----------------
# `ratchet` floats with the nixpkgs input while three sites assert a
# specific number, so the mismatch has to be reachable. RATCHET_VERSION
# _OVERRIDE stands in for the installed tool, which keeps the case
# offline and does not need a second ratchet on PATH.
# @arg $1 doc fixture  @arg $2 workflow fixture  @arg $3 stand-in version
# @arg $4 expected exit  @arg $5 expected stderr substring
function expect_version() {
  local -r doc="$1" workflow="$2" version="$3" want_exit="$4" want_msg="$5"
  local got_exit=0 got_stderr
  got_stderr="$(RATCHET_VERSION_OVERRIDE="${version}" \
    RATCHET_DOC_OVERRIDE="${FIXTURES}/${doc}" \
    WORKFLOW_PATH_OVERRIDE="${FIXTURES}/${workflow}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s @ %s: exit %s, want %s\n  stderr: %s\n' \
      "${doc}" "${version}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s @ %s: stderr missing %q\n  got: %s\n' \
      "${doc}" "${version}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s @ %s\n' "${doc}" "${version}"
}

expect_version version-stated.md good.yml 0.11.4 0 ""
expect_version version-stated.md good.yml 0.12.0 1 \
  "does not match the devShell's ratchet 0.12.0"
# A reword that drops every literal leaves nothing to compare. Removing
# the version claim is a decision, so it fails rather than passing quiet.
expect_version version-absent.md version-absent.yml 0.11.4 1 \
  "version site found in"
# A version string the tool did not produce is a could-not-run: scoring
# it as a mismatch would report drift the check never actually measured.
expect_version version-stated.md good.yml 'not-a-version' 2 \
  "could not read a version"

# --- classify-pin-ref.sh verdict tests -------------------------------
# Pure classifier: <tag> <pinned> <ref_object_sha> <ref_object_type>
# <deref_commit_sha>. Fake 40-hex SHAs keep the cases offline and
# deterministic; only equality/inequality and tag shape matter.
readonly CLASSIFY="${REPO_ROOT}/scripts/classify-pin-ref.sh"

function classify() {
  local -r desc="$1" want="$2"
  shift 2
  local got rc=0
  got="$(bash "${CLASSIFY}" "$@" 2>/dev/null)" || rc=$?
  if [[ ${want} == "<error>" ]]; then
    if [[ ${rc} -eq 0 ]]; then
      printf 'FAIL classify %s: expected non-zero exit\n' "${desc}" >&2
      return 1
    fi
    printf 'OK   classify %s (exit %d)\n' "${desc}" "${rc}"
    return 0
  fi
  if [[ ${rc} -ne 0 ]]; then
    printf 'FAIL classify %s: exit %d, want %s\n' "${desc}" "${rc}" "${want}" >&2
    return 1
  fi
  if [[ ${got} != "${want}" ]]; then
    printf 'FAIL classify %s: got %q want %q\n' "${desc}" "${got}" "${want}" >&2
    return 1
  fi
  printf 'OK   classify %s\n' "${desc}"
}

# tag-object pin of an unmoved annotated tag: pinned == tag object.
classify "tag-object pin, unmoved annotated tag" current \
  v9.0.0 dddddddddddddddddddddddddddddddddddddddd \
  dddddddddddddddddddddddddddddddddddddddd tag \
  cccccccccccccccccccccccccccccccccccccccc
# commit pin of an annotated tag: pinned == dereferenced commit.
classify "commit pin, annotated tag" current \
  v9.0.0 cccccccccccccccccccccccccccccccccccccccc \
  dddddddddddddddddddddddddddddddddddddddd tag \
  cccccccccccccccccccccccccccccccccccccccc
# lightweight tag: object is the commit, no deref.
classify "commit pin, lightweight tag" current \
  v4.3.1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa commit ""
# lightweight tag force-moved: object is a commit, pin matches neither
# the new ref object nor the (empty) deref commit -> drift.
classify "lightweight-tag force-move -> drift" drift \
  v4.3.1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit ""
# genuine force-move: pin matches neither new object nor new commit.
classify "genuine force-move -> drift" drift \
  v9.0.0 dddddddddddddddddddddddddddddddddddddddd \
  eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee tag \
  ffffffffffffffffffffffffffffffffffffffff
# floating major: skip regardless of SHAs.
classify "floating major -> skip" skip-floating-major \
  v31 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  7777777777777777777777777777777777777777 tag \
  8888888888888888888888888888888888888888
# patch tag with a major-looking prefix is NOT skipped.
classify "patch tag not over-skipped" drift \
  v31.2.0 1111111111111111111111111111111111111111 \
  2222222222222222222222222222222222222222 tag \
  3333333333333333333333333333333333333333
# usage error: too few args.
classify "usage error (too few args)" "<error>" v9.0.0 deadbeef

printf 'all tests passed\n'
