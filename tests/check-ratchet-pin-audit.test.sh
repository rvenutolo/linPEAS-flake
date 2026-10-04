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
# A workflow that does not parse is the same kind of answer as an absent
# one: no invariant was read, so it is not a failed invariant. The file
# is written at run time rather than kept in the tree, because the
# formatters refuse to touch unparsable YAML. yq exits 1 on it, and an
# unchecked read would report that as hardening drift.
function expect_unparsable() {
  local dir got_exit=0 got_stderr
  dir="$(mktemp --directory)"
  printf 'jobs: [\n' >"${dir}/ratchet-pin-audit.yml"
  got_stderr="$(WORKFLOW_PATH_OVERRIDE="${dir}/ratchet-pin-audit.yml" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --recursive --force -- "${dir}"
  if [[ ${got_exit} != 2 ]]; then
    printf 'FAIL unparsable workflow: exit %s, want 2\n  stderr: %s\n' \
      "${got_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ ${got_stderr} != *'cannot read'* ]]; then
    printf 'FAIL unparsable workflow: stderr missing %q\n  got: %s\n' \
      'cannot read' "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   unparsable workflow is a tooling error\n'
}
expect_unparsable

# --- shapes of permissions: and on:, built from good.yml at run time ---
# A formatter would rewrite a tagged or quoted node checked in as a
# fixture. Each scenario asserts the whole of stderr.

# @description Run the script on good.yml with one line replaced (or a
# text appended), and compare the exit code and the whole of stderr.
# @arg $1 scenario name
# @arg $2 the line of good.yml to replace (empty: replace nothing)
# @arg $3 its replacement, printf-style (may span lines)
# @arg $4 text appended to the file, printf-style (may be empty)
# @arg $5 expected exit code
# @arg $6 expected stderr
function expect_shape() {
  local -r name="$1" old="$2" new="$3" tail="$4" want_exit="$5" want="$6"
  local dir content got_exit=0 got_stderr replacement appended
  dir="$(mktemp --directory)"
  content="$(<"${FIXTURES}/good.yml")"
  # printf -v keeps a trailing line break a substitution would drop.
  # shellcheck disable=SC2059 # the replacement is the format
  printf -v replacement -- "${new}"
  # shellcheck disable=SC2059 # the appended text is the format
  printf -v appended -- "${tail}"
  if [[ -n ${old} ]]; then
    local rest="${content#*"${old}"}"
    if [[ ${rest} == "${content}" || ${rest} == *"${old}"* ]]; then
      printf 'HARNESS BUG: %q does not occur exactly once in good.yml\n' "${old}" >&2
      exit 1
    fi
    content="${content/"${old}"/"${replacement}"}"
  fi
  printf '%s\n%s' "${content}" "${appended}" >"${dir}/wf.yml"
  got_stderr="$(WORKFLOW_PATH_OVERRIDE="${dir}/wf.yml" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  local expected="${want//%W/${dir}/wf.yml}"
  rm --recursive --force -- "${dir}"
  # yq's own lines are not the lint's: its timestamped merge-key warning
  # is dropped, and `YQ_ERROR` on a line of its own stands for one line of
  # yq's error, which must open with `Error: `.
  local line kept=''
  while IFS= read -r line; do
    [[ ${line} == 'time='*' level=WARN '* ]] && continue
    kept+="${kept:+$'\n'}${line}"
  done <<<"${got_stderr}"
  got_stderr="${kept}"
  if [[ ${expected} == YQ_ERROR$'\n'* ]]; then
    if [[ ${got_stderr} != 'Error: '*$'\n'* ]]; then
      printf 'FAIL %s: stderr does not open with a line of yq'"'"'s own\n  got: %q\n' "${name}" "${got_stderr}" >&2
      return 1
    fi
    expected="${expected#YQ_ERROR$'\n'}"
    got_stderr="${got_stderr#*$'\n'}"
  fi
  if [[ ${got_exit} != "${want_exit}" || ${got_stderr} != "${expected}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  got:  %q\n  want: %q\n' \
      "${name}" "${got_exit}" "${want_exit}" "${got_stderr}" "${expected}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${name}"
}

readonly PERMS_LINE=$'\npermissions: {}\n'
readonly SCHED_LINES=$'  schedule:\n    - cron: "0 11 * * *" # daily 11:00 UTC\n'
readonly ON_BLOCK=$'on:\n  schedule:\n    - cron: "0 11 * * *" # daily 11:00 UTC\n  workflow_dispatch:\n'
readonly ONE_FAILED='1 invariant(s) failed'

# permissions: is read by kind, through an alias.
expect_shape 'an empty scalar carrying the map tag is no empty map' \
  "${PERMS_LINE}" "\\npermissions: !!map ''\\n" '' 1 \
  "top-level permissions must be {} (got kind=scalar tag=!!map length=0)
${ONE_FAILED}"
expect_shape 'an empty map carrying a tag of its own is an empty map' \
  "${PERMS_LINE}" '\npermissions: !x {}\n' '' 0 ''
expect_shape 'an empty list carrying the map tag is no empty map' \
  "${PERMS_LINE}" '\npermissions: !!map []\n' '' 1 \
  "top-level permissions must be {} (got kind=seq tag=!!map length=0)
${ONE_FAILED}"
expect_shape 'permissions: written as an alias of an empty map passes' \
  "${PERMS_LINE}" '\nx-p: &p {}\npermissions: *p\n' '' 0 ''
expect_shape 'permissions: written as an alias of a granting map is a finding' \
  "${PERMS_LINE}" '\nx-p: &p {contents: read}\npermissions: *p\n' '' 1 \
  "top-level permissions must be {} (got kind=map tag=!!map length=1)
${ONE_FAILED}"
expect_shape 'a map tag holding a space is printed whole' \
  "${PERMS_LINE}" '\npermissions: !<x%%200> {a: b}\n' '' 1 \
  "top-level permissions must be {} (got kind=map tag=x 0 length=1)
${ONE_FAILED}"

# on: is read from ON_NODE by kind; schedule must be a non-empty list.
expect_shape 'a scalar carrying the list tag is no schedule' \
  "${SCHED_LINES}" '  schedule: !!seq x\n' '' 1 \
  "on: must include a schedule sequence (got kind=scalar tag=!!seq length=1)
${ONE_FAILED}"
expect_shape 'an empty scalar carrying the list tag is no schedule' \
  "${SCHED_LINES}" "  schedule: !!seq ''\\n" '' 1 \
  "on: must include a schedule sequence (got kind=scalar tag=!!seq length=0)
${ONE_FAILED}"
expect_shape 'an empty schedule list runs nothing' \
  "${SCHED_LINES}" '  schedule: []\n' '' 1 \
  "on: must include a schedule sequence (got kind=seq tag=!!seq length=0)
${ONE_FAILED}"
expect_shape 'a schedule list carrying a tag of its own is a schedule' \
  "${SCHED_LINES}" '  schedule: !x [{cron: "0 11 * * *"}]\n' '' 0 ''
expect_shape 'a schedule written as an alias is read through it' \
  "${ON_BLOCK}" 'x-s: &s [{cron: "0 11 * * *"}]\non:\n  schedule: *s\n  workflow_dispatch:\n' '' 0 ''
expect_shape 'an on: alias holding a schedule alias is read through both' \
  "${ON_BLOCK}" 'x-s: &s [{cron: "0 11 * * *"}]\nx-o: &o {schedule: *s, workflow_dispatch: }\non: *o\n' '' 0 ''
expect_shape 'an on: written as an alias is read through it' \
  "${ON_BLOCK}" 'x-o: &o {schedule: [{cron: "0 11 * * *"}], workflow_dispatch: }\non: *o\n' '' 0 ''
expect_shape 'an on: with no schedule names its absence' \
  "${SCHED_LINES}" '' '' 1 \
  "on: must include a schedule sequence (got kind=absent tag=- length=0)
${ONE_FAILED}"
expect_shape 'an on: given as a list holds neither schedule nor dispatch' \
  "${ON_BLOCK}" 'on: [schedule, workflow_dispatch]\n' '' 1 \
  "on: must include a schedule sequence (got kind=absent tag=- length=0)
on: must include workflow_dispatch
2 invariant(s) failed"
expect_shape 'on: given twice stops the run' \
  "${ON_BLOCK}" "${ON_BLOCK//%/%%}"'"on": push\n' '' 2 \
  "Error: on: is given more than once
cannot read the on: schedule from %W"

# An alias chain deeper than ON_NODE's passes stops the run too: each
# anchor holds a list holding an alias of the one before.
deep='x-a0: &a0 [workflow_dispatch]\n'
for i in $(seq 1 17); do
  deep+="x-a${i}: &a${i} [*a$((i - 1))]\\n"
done
expect_shape 'an on: alias nested too deep to resolve stops the run' \
  "${ON_BLOCK}" "${deep}"'on:\n  schedule: [{cron: "0 11 * * *"}]\n  workflow_dispatch:\n  x: *a17\n' '' 2 \
  "Error: on: holds an alias nested too deep to resolve
cannot read the on: schedule from %W"
expect_shape 'a merge key in on: that brings in a list stops the run' \
  "${ON_BLOCK}" 'x-l: &l [a]\non:\n  schedule: {<<: *l}\n  workflow_dispatch:\n' '' 2 \
  "YQ_ERROR
cannot read the on: schedule from %W"

# Several documents are one finding; a trailing --- starts a second one.
expect_shape 'a trailing document separator is several documents' \
  '' '' '---\n' 1 \
  "workflow holds several YAML documents, which GitHub Actions refuses; it is read no further
${ONE_FAILED}"
expect_shape 'a second document is several documents' \
  '' '' '---\npermissions: {contents: write}\n' 1 \
  "workflow holds several YAML documents, which GitHub Actions refuses; it is read no further
${ONE_FAILED}"

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
