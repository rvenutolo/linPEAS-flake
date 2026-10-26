#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-ratchet-pin-audit.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/ratchet-pin-audit"
# shellcheck source=scripts/lib/locale-gap.sh
source "${REPO_ROOT}/scripts/lib/locale-gap.sh"
# The version and floating-major scenarios below pin en_US.UTF-8, where a
# bash [0-9] range admits non-ASCII digits.
require_locale_gap en_US.UTF-8 || exit 1

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
# @arg $7 root keys inserted after the first line, printf-style, where
#   the anchors a replacement aliases are defined (optional). With them,
#   yq's merge-key warning is not dropped: an aliased read passes the
#   merge specification, so stderr must hold no warning at all.
function expect_shape() {
  local -r name="$1" old="$2" new="$3" tail="$4" want_exit="$5" want="$6" anchors="${7:-}"
  local dir content got_exit=0 got_stderr replacement appended
  dir="$(mktemp --directory)"
  content="$(<"${FIXTURES}/good.yml")"
  if [[ -n ${anchors} ]]; then
    local anchor_text
    # shellcheck disable=SC2059 # the anchor text is the format
    printf -v anchor_text -- "${anchors}"
    content="${content%%$'\n'*}"$'\n'"${anchor_text}${content#*$'\n'}"
  fi
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
  # is dropped (except under anchors, see $7), and `YQ_ERROR` on a line of
  # its own stands for one line of yq's error, which must open with
  # `Error: `.
  local line kept=''
  while IFS= read -r line; do
    [[ -z ${anchors} && ${line} == 'time='*' level=WARN '* ]] && continue
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
expect_shape 'permissions: written as a root key alias of a granting map is a finding' \
  "${PERMS_LINE}" '\nrun-name: &k permissions\n*k : {contents: read}\n' '' 1 \
  "top-level permissions must be {} (got kind=map tag=!!map length=1)
${ONE_FAILED}"
expect_shape 'permissions: given twice, plain and as a root key alias, stops the run' \
  "${PERMS_LINE}" '\npermissions: {}\nrun-name: &k permissions\n*k : {}\n' '' 2 \
  "Error: permissions: is given more than once
cannot read the top-level permissions from %W"
expect_shape 'a map tag holding a space is printed whole' \
  "${PERMS_LINE}" '\npermissions: !<x%%200> {a: b}\n' '' 1 \
  "top-level permissions must be {} (got kind=map tag=x 0 length=1)
${ONE_FAILED}"

# A root key written as an alias of `jobs` or `concurrency` is that key,
# as GitHub Actions reads it; one given twice, plain and as an alias,
# stops the run.
expect_shape 'jobs: written as a root key alias is read through it' \
  $'\njobs:\n' '\nrun-name: &k jobs\n*k :\n' '' 0 ''
expect_shape 'jobs: given twice, plain and as a root key alias, stops the run' \
  $'\njobs:\n' '\njobs: {}\nrun-name: &k jobs\n*k :\n' '' 2 \
  "Error: jobs: is given more than once
cannot read the timeout-minutes of job check from %W"
expect_shape 'concurrency: written as a root key alias is read through it' \
  $'\nconcurrency:\n' '\nrun-name: &k concurrency\n*k :\n' '' 0 ''
expect_shape 'concurrency: given twice, plain and as a root key alias, stops the run' \
  $'\nconcurrency:\n' '\nconcurrency: {group: ratchet-pin-audit}\nrun-name: &k concurrency\n*k :\n' '' 2 \
  "Error: concurrency: is given more than once
cannot read the concurrency group from %W"

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

# A root that is not a map is one finding, read no further.
for root in 'hello' '- push'; do
  root_dir="$(mktemp --directory)"
  printf '%s\n' "${root}" >"${root_dir}/wf.yml"
  root_exit=0
  root_stderr="$(WORKFLOW_PATH_OVERRIDE="${root_dir}/wf.yml" "${SCRIPT}" 2>&1 >/dev/null)" || root_exit=$?
  rm --recursive --force -- "${root_dir}"
  root_kind=scalar
  [[ ${root} == -* ]] && root_kind=seq
  root_want="workflow root is not a map (kind=${root_kind}); it is read no further"$'\n'"${ONE_FAILED}"
  if [[ ${root_exit} != 1 || ${root_stderr} != "${root_want}" ]]; then
    printf 'FAIL a %s root is one finding: exit %s\n  got:  %q\n  want: %q\n' "${root_kind}" "${root_exit}" "${root_stderr}" "${root_want}" >&2
    exit 1
  fi
  printf 'OK   a %s root is one finding\n' "${root_kind}"
done

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

# In en_US.UTF-8 a bash [0-9] range also matches non-ASCII digits, so a
# version the tool cannot have printed would be compared as a version and
# reported as drift. The whole of stderr is compared.
# @arg $1 stand-in version  @arg $2 expected exit  @arg $3 whole stderr
function expect_version_en_us() {
  local -r version="$1" want_exit="$2" want_stderr="$3"
  local got_exit=0 got_stderr
  got_stderr="$(LC_ALL=en_US.UTF-8 RATCHET_VERSION_OVERRIDE="${version}" \
    RATCHET_DOC_OVERRIDE="${FIXTURES}/version-stated.md" \
    WORKFLOW_PATH_OVERRIDE="${FIXTURES}/good.yml" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" || ${got_stderr} != "${want_stderr}" ]]; then
    printf 'FAIL en_US.UTF-8 @ %s: exit %s, want %s\n  stderr: %s\n  want:   %s\n' \
      "${version}" "${got_exit}" "${want_exit}" "${got_stderr}" "${want_stderr}" >&2
    return 1
  fi
  printf 'OK   en_US.UTF-8 @ %s\n' "${version}"
}

expect_version_en_us 0.11.4 0 ""
expect_version_en_us '0.11.٤' 2 'could not read a version from ratchet --version (got 0.11.٤)'
expect_version_en_us '0.11.５' 2 'could not read a version from ratchet --version (got 0.11.５)'
expect_version_en_us '0.1².4' 2 'could not read a version from ratchet --version (got 0.1².4)'
expect_version_en_us '٠.11.4' 2 'could not read a version from ratchet --version (got ٠.11.4)'
expect_version_en_us 'é0.11.4' 2 'could not read a version from ratchet --version (got é0.11.4)'
expect_version_en_us '0.11.4é' 2 'could not read a version from ratchet --version (got 0.11.4é)'

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
# Under en_US.UTF-8 a bash [0-9] range also matches non-ASCII digits; a
# tag holding one is not a floating major, so a moved pin is drift.
LC_ALL=en_US.UTF-8 classify "Arabic-Indic digit tag is not a floating major under en_US.UTF-8" drift \
  'v٣' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  7777777777777777777777777777777777777777 tag \
  8888888888888888888888888888888888888888
LC_ALL=en_US.UTF-8 classify "fullwidth digit tag is not a floating major under en_US.UTF-8" drift \
  'v５' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  7777777777777777777777777777777777777777 tag \
  8888888888888888888888888888888888888888
LC_ALL=en_US.UTF-8 classify "superscript digit tag is not a floating major under en_US.UTF-8" drift \
  'v²' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  7777777777777777777777777777777777777777 tag \
  8888888888888888888888888888888888888888
LC_ALL=en_US.UTF-8 classify "mixed-digit tag is not a floating major under en_US.UTF-8" drift \
  'v1٢' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  7777777777777777777777777777777777777777 tag \
  8888888888888888888888888888888888888888
LC_ALL=en_US.UTF-8 classify "text before a floating major is not one under en_US.UTF-8" drift \
  'év31' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  7777777777777777777777777777777777777777 tag \
  8888888888888888888888888888888888888888
LC_ALL=en_US.UTF-8 classify "ASCII floating major still skips under en_US.UTF-8" skip-floating-major \
  v31 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  7777777777777777777777777777777777777777 tag \
  8888888888888888888888888888888888888888
# usage error: too few args.
classify "usage error (too few args)" "<error>" v9.0.0 deadbeef

# --- merge list inside the named check job, built from good.yml ---
# A merge list gives the first mapping the win, as the YAML merge
# specification says; yq reads the last one unless told otherwise.
# @arg $1 scenario name
# @arg $2 the merge list, in the order under test
# @arg $3 expected exit code
# @arg $4 expected stderr
function expect_merge_order() {
  local -r name="$1" order="$2" want_exit="$3" want="$4"
  local dir content got_exit=0 got_stderr
  dir="$(mktemp --directory)"
  content="$(<"${FIXTURES}/good.yml")"
  {
    printf '%s\n' "${content%%$'\njobs:'*}"
    printf 'x-write: &write\n  permissions:\n    contents: write\n  steps:\n    - uses: step-security/harden-runner@ab7a9404c0f3da075243ca237b5fac12c98deaa5\n'
    printf 'x-read: &read\n  timeout-minutes: 15\n  permissions:\n    contents: read\n  steps:\n    - uses: step-security/harden-runner@ab7a9404c0f3da075243ca237b5fac12c98deaa5\n'
    printf 'jobs:\n  check:\n    <<: %s\n' "${order}"
    printf '  notify:%s\n' "${content#*$'\n'  notify:}"
  } >"${dir}/wf.yml"
  got_stderr="$(WORKFLOW_PATH_OVERRIDE="${dir}/wf.yml" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --recursive --force -- "${dir}"
  if [[ ${got_exit} != "${want_exit}" || ${got_stderr} != "${want}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  got:  %q\n  want: %q\n' \
      "${name}" "${got_exit}" "${want_exit}" "${got_stderr}" "${want}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${name}"
}
# The notify job's read scopes are part of its exact set: the composite's
# self-classification needs them, and a notify job holding only the write
# scope would fail that fetch and file every transient it should hold off.
expect_shape 'a notify job without its read scopes is refused' \
  $'      actions: read\n      checks: read\n      issues: write\n' $'      issues: write\n' '' 1 \
  "job notify: permissions must be exactly { actions: read, checks: read, issues: write } (got: issues:write)
${ONE_FAILED}"
expect_merge_order 'a merge list in the check job is read first mapping wins: the writer first is refused' \
  '[*write, *read]' 1 \
  "job check: permissions must be exactly { contents: read } (got: contents:write)
${ONE_FAILED}"
expect_merge_order 'a merge list in the check job is read first mapping wins: the reader first passes' \
  '[*read, *write]' 0 ''

# Respelling an action in another case must not take it out of an
# invariant's reach, so the first-step and checkout invariants read an
# action whatever the case of the ASCII letters in its owner and repository.
readonly CHECK_HR='      - uses: step-security/harden-runner@ab7a9404c0f3da075243ca237b5fac12c98deaa5 # v2.19.3\n        with:\n          egress-policy: audit\n'
readonly CHECK_CHECKOUT='      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1\n        with:\n          persist-credentials: false\n'
readonly CHECK_NIX='      - uses: ./.github/actions/setup-nix'
# shellcheck disable=SC2059 # the step text is the format
printf -v CHECK_STEPS -- "${CHECK_HR}${CHECK_CHECKOUT}${CHECK_NIX}"
readonly CHECK_STEPS
expect_shape 'a first step spelled in mixed case is harden-runner' \
  "${CHECK_STEPS}" "${CHECK_HR/step-security\/harden-runner/Step-Security\/Harden-Runner}${CHECK_CHECKOUT}${CHECK_NIX}" '' 0 ''
expect_shape 'a checkout step spelled in mixed case that keeps credentials is counted' \
  "${CHECK_STEPS}" "${CHECK_HR}"'      - uses: Actions/Checkout@34e114876b0b11c390a56381ad16ebd13914f8d5\n        with:\n          persist-credentials: true\n'"${CHECK_NIX}" '' 1 \
  "actions/checkout: 2 steps total, only 1 set persist-credentials: false
${ONE_FAILED}"

# --- values written as aliases, built from good.yml at run time ---
# Each value the lint reads, written as an alias, gets the verdict and
# the diagnostic of the same value written inline. The anchors are root
# keys the lint never reads.
readonly HR_PIN='step-security/harden-runner@ab7a9404c0f3da075243ca237b5fac12c98deaa5'
readonly CHECKOUT_PIN='actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5'
readonly OTHER_PIN='actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830'
readonly CHECK_TIMEOUT=$'    timeout-minutes: 15\n'
readonly CHECK_PERMS=$'    permissions:\n      contents: read\n'
readonly CONC_GROUP=$'  group: ratchet-pin-audit\n'
readonly NOTIFY_USES=$'      - uses: ./.github/actions/notify-workflow-result\n'
readonly BODY_HEAD=$'          body: |\n'
# shellcheck disable=SC2016 # backticks are literal Markdown in the body
readonly ALL_TOKENS='"`drift-detected` `upstream-api-failure` `ratchet-tool-failure` `unknown`"'
# shellcheck disable=SC2016 # backticks are literal Markdown in the body
readonly THREE_TOKENS='"`drift-detected` `upstream-api-failure` `ratchet-tool-failure`"'
readonly TIMEOUT_MISSING="job check: timeout-minutes missing
${ONE_FAILED}"
readonly CREDENTIALS_KEPT="actions/checkout: 2 steps total, only 1 set persist-credentials: false
${ONE_FAILED}"
readonly OTHER_FIRST="job check: first step must be step-security/harden-runner (got: ${OTHER_PIN})
${ONE_FAILED}"
readonly OTHER_GROUP="concurrency.group must be \"ratchet-pin-audit\" (got: \"other\")
${ONE_FAILED}"
readonly NULL_GROUP="concurrency.group must be \"ratchet-pin-audit\" (got: \"\")
${ONE_FAILED}"
readonly TOKEN_MISSING="notify body missing reason token: unknown
${ONE_FAILED}"
readonly WRITE_PERMS="job check: permissions must be exactly { contents: read } (got: contents:write)
${ONE_FAILED}"
readonly NESTED_PERMS="job check: permissions must be exactly { contents: read } (got: contents:[[[[[read]]]]])
${ONE_FAILED}"

# timeout-minutes: an alias of null is a missing timeout, as null is.
expect_shape 'a timeout-minutes of null is missing' \
  "${CHECK_TIMEOUT}" '    timeout-minutes: null\n' '' 1 "${TIMEOUT_MISSING}"
expect_shape 'a timeout-minutes written as an alias of null is missing' \
  "${CHECK_TIMEOUT}" '    timeout-minutes: *t\n' '' 1 "${TIMEOUT_MISSING}" \
  'x-t: &t null\n'
expect_shape 'a timeout-minutes written as an alias of a number is set' \
  "${CHECK_TIMEOUT}" '    timeout-minutes: *t\n' '' 0 '' \
  'x-t: &t 15\n'

# The first step's uses: is read as its anchored text.
expect_shape 'a first step written as an alias of harden-runner is harden-runner' \
  "${CHECK_STEPS}" "      - uses: *u\\n        with:\\n          egress-policy: audit\\n${CHECK_CHECKOUT}${CHECK_NIX}" '' 0 '' \
  "x-u: &u ${HR_PIN}\\n"
expect_shape 'a first step of another action is named' \
  "${CHECK_STEPS}" "      - uses: ${OTHER_PIN}\\n${CHECK_CHECKOUT}${CHECK_NIX}" '' 1 "${OTHER_FIRST}"
expect_shape 'a first step written as an alias of another action is named by its text' \
  "${CHECK_STEPS}" "      - uses: *u\\n${CHECK_CHECKOUT}${CHECK_NIX}" '' 1 "${OTHER_FIRST}" \
  "x-u: &u ${OTHER_PIN}\\n"

# A checkout step is found through an aliased uses:, and its
# persist-credentials: is read through an alias.
expect_shape 'a checkout step that keeps credentials is counted' \
  "${CHECK_STEPS}" "${CHECK_HR}      - uses: ${CHECKOUT_PIN}\\n        with:\\n          persist-credentials: true\\n${CHECK_NIX}" '' 1 \
  "${CREDENTIALS_KEPT}"
expect_shape 'a checkout step written as an alias that keeps credentials is counted' \
  "${CHECK_STEPS}" "${CHECK_HR}      - uses: *u\\n        with:\\n          persist-credentials: true\\n${CHECK_NIX}" '' 1 \
  "${CREDENTIALS_KEPT}" "x-u: &u ${CHECKOUT_PIN}\\n"
expect_shape 'a persist-credentials written as an alias of false is false' \
  "${CHECK_STEPS}" "${CHECK_HR}      - uses: ${CHECKOUT_PIN}\\n        with:\\n          persist-credentials: *f\\n${CHECK_NIX}" '' 0 '' \
  'x-f: &f false\n'
expect_shape 'a persist-credentials written as an alias of true keeps credentials' \
  "${CHECK_STEPS}" "${CHECK_HR}      - uses: ${CHECKOUT_PIN}\\n        with:\\n          persist-credentials: *f\\n${CHECK_NIX}" '' 1 \
  "${CREDENTIALS_KEPT}" 'x-f: &f true\n'

# concurrency.group is read as its anchored text, an alias of null as
# null is.
expect_shape 'a concurrency group written as an alias is read as its text' \
  "${CONC_GROUP}" '  group: *g\n' '' 0 '' \
  'x-g: &g ratchet-pin-audit\n'
expect_shape 'a concurrency group of null is empty' \
  "${CONC_GROUP}" '  group: null\n' '' 1 "${NULL_GROUP}"
expect_shape 'a concurrency group written as an alias of null is empty' \
  "${CONC_GROUP}" '  group: *g\n' '' 1 "${NULL_GROUP}" \
  'x-g: &g null\n'
expect_shape 'a concurrency group of another name is named' \
  "${CONC_GROUP}" '  group: other\n' '' 1 "${OTHER_GROUP}"
expect_shape 'a concurrency group written as an alias of another name is named by its text' \
  "${CONC_GROUP}" '  group: *g\n' '' 1 "${OTHER_GROUP}" 'x-g: &g other\n'

# The notify step is found through an aliased uses:, and its body is
# read as its anchored text. The checked-in body moves to a key the lint
# never reads.
expect_shape 'a notify step written as an alias is the notify step' \
  "${NOTIFY_USES}" '      - uses: *n\n' '' 0 '' \
  'x-n: &n ./.github/actions/notify-workflow-result\n'
expect_shape 'a notify body holding every reason token passes' \
  "${BODY_HEAD}" "          body: ${ALL_TOKENS}\\n          x-body: |\\n" '' 0 ''
expect_shape 'a notify body written as an alias is read as its text' \
  "${BODY_HEAD}" '          body: *b\n          x-body: |\n' '' 0 '' \
  "x-b: &b ${ALL_TOKENS}\\n"
expect_shape 'a notify body missing a reason token names it' \
  "${BODY_HEAD}" "          body: ${THREE_TOKENS}\\n          x-body: |\\n" '' 1 "${TOKEN_MISSING}"
expect_shape 'a notify body written as an alias missing a reason token names it' \
  "${BODY_HEAD}" '          body: *b\n          x-body: |\n' '' 1 "${TOKEN_MISSING}" \
  "x-b: &b ${THREE_TOKENS}\\n"

# A job's permissions are read through an alias of the map, a merge key
# and an alias of a value, however deep the nest, up to sixteen passes.
expect_shape 'a check permission written as an alias is read as its text' \
  "${CHECK_PERMS}" '    permissions:\n      contents: *r\n' '' 0 '' \
  'x-r: &r read\n'
expect_shape 'a check permission of write is named' \
  "${CHECK_PERMS}" '    permissions:\n      contents: write\n' '' 1 "${WRITE_PERMS}"
expect_shape 'a check permission written as an alias of write is named by its text' \
  "${CHECK_PERMS}" '    permissions:\n      contents: *w\n' '' 1 "${WRITE_PERMS}" \
  'x-w: &w write\n'
expect_shape 'check permissions written as an alias are read as their map' \
  "${CHECK_PERMS}" '    permissions: *p\n' '' 0 '' \
  'x-p: &p {contents: read}\n'
expect_shape 'check permissions written as a merge key are read as the merged map' \
  "${CHECK_PERMS}" '    permissions: {<<: *p}\n' '' 0 '' \
  'x-p: &p {contents: read}\n'
expect_shape 'check permissions written as a merge key of a writer are named' \
  "${CHECK_PERMS}" '    permissions: {<<: *p}\n' '' 1 "${WRITE_PERMS}" \
  'x-p: &p {contents: write}\n'
expect_shape 'check permissions three aliases deep are read as their text' \
  "${CHECK_PERMS}" '    permissions: *q\n' '' 0 '' \
  'x-r: &r read\nx-p: &p {contents: *r}\nx-q: &q {<<: *p}\n'
expect_shape 'a check permission nested five lists deep is named' \
  "${CHECK_PERMS}" '    permissions:\n      contents: [[[[[read]]]]]\n' '' 1 "${NESTED_PERMS}"
expect_shape 'a check permission nested five aliases deep is named by its text' \
  "${CHECK_PERMS}" '    permissions:\n      contents: *a4\n' '' 1 "${NESTED_PERMS}" \
  'x-a0: &a0 [read]\nx-a1: &a1 [*a0]\nx-a2: &a2 [*a1]\nx-a3: &a3 [*a2]\nx-a4: &a4 [*a3]\n'

# A permission value still holding an alias after sixteen passes has no
# text to judge, so the run stops on it; the same nest anywhere the lint
# never reads leaves the verdict alone. Each anchor holds a list holding
# an alias of the one before.
perm_deep='x-a0: &a0 [read]\n'
for i in $(seq 1 17); do
  perm_deep+="x-a${i}: &a${i} [*a$((i - 1))]\\n"
done
readonly perm_deep
expect_shape 'a check permission nested deeper than sixteen aliases stops the run' \
  "${CHECK_PERMS}" '    permissions:\n      contents: *a17\n' '' 2 \
  "Error: jobs.check.permissions holds an alias nested too deep to resolve
cannot read the permissions of job check from %W" "${perm_deep}"
expect_shape 'an alias nested deeper than sixteen in a value the lint never reads is not read' \
  $'          label: ratchet-drift\n' '          label: *a17\n' '' 0 '' "${perm_deep}"

printf 'all tests passed\n'
