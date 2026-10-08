#!/usr/bin/env bash
# tests/check-size-label-ignores.test.sh
#
# Spec-driven harness for scripts/check-size-label-ignores.sh. Drives the
# lint against a fixture scripts/ root and a fixture labeler workflow via
# SCRIPTS_DIR_OVERRIDE + LABELER_YML_OVERRIDE, then asserts it holds on
# the live tree.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-size-label-ignores.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/size-label-ignores"
readonly DECLARING_SCRIPTS="${FIXTURES}/scripts"
readonly SILENT_SCRIPTS="${FIXTURES}/no-declarations/scripts"

failures=0

# Declared top-level so the EXIT trap can reach across function boundaries.
work=''
function cleanup() {
  if [[ -n ${work:-} && -d ${work} ]]; then
    rm --recursive --force -- "${work}"
  fi
}
trap cleanup EXIT

# ${1}=scenario name  ${2}=scripts root  ${3}=labeler path
# ${4}=wanted exit    ${5}=wanted stderr substring ('' for none)
# ${6}=1 to run with LINT_ALLOW_EMPTY_SCAN set (default: unset)
# ${7}=the whole wanted stderr, and ${8} the whole wanted stdout ('' for
#      either skips it)
function expect() {
  local -r name="$1" scripts_dir="$2" labeler="$3" want_exit="$4" want_msg="$5"
  local -r allow_empty="${6:-}" want_stderr="${7:-}" want_stdout="${8:-}"

  local stdout_file stderr_file outcome_file
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local got_exit=0
  LINT_ALLOW_EMPTY_SCAN="${allow_empty}" \
    SCRIPTS_DIR_OVERRIDE="${scripts_dir}" \
    LABELER_YML_OVERRIDE="${labeler}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${want_msg}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"

  local got_stderr
  got_stderr="$(cat -- "${stderr_file}")"
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' \
      "${name}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    failures=$((failures + 1))
  elif [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' \
      "${name}" "${want_msg}" "${got_stderr}" >&2
    failures=$((failures + 1))
  elif [[ -n ${want_stderr} && ${got_stderr} != "${want_stderr}" ]]; then
    printf 'FAIL %s: stderr is not %q\n  got: %s\n' \
      "${name}" "${want_stderr}" "${got_stderr}" >&2
    failures=$((failures + 1))
  elif [[ -n ${want_stdout} && $(<"${stdout_file}") != "${want_stdout}" ]]; then
    printf 'FAIL %s: stdout is not %q\n  got: %s\n' \
      "${name}" "${want_stdout}" "$(<"${stdout_file}")" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %s)\n' "${name}" "${got_exit}"
  fi

  rm --force -- "${stdout_file}" "${stderr_file}" "${outcome_file}"
}

function main() {
  work="$(mktemp --directory)"
  # Written here rather than checked in: prettier refuses to format
  # invalid YAML, so a checked-in copy would need a formatter exclusion
  # to survive the tree's own gates.
  printf 'name: bad-malformed\njobs:\n  size: [ this is not yaml\n' \
    >"${work}/bad-malformed.yml"

  # (a) GOOD: the one `@generates` path is on the list, the
  # `@generates-block` path is not, and the remaining entry is exempt.
  expect 'agree: declarations and the ignore list match' \
    "${DECLARING_SCRIPTS}" "${FIXTURES}/good.yml" 0 ''

  # (b) GOOD: every exemption the lint declares is accepted, so an entry
  # nothing under scripts/ writes is not forced to invent a generator.
  expect 'agree: every declared exemption is accepted' \
    "${DECLARING_SCRIPTS}" "${FIXTURES}/good-exempt-entries.yml" 0 ''

  # (c) BAD: rule 1. A generator owns a file the ignore list never
  # learned about, so every PR that regenerates it is sized as authored
  # change.
  expect 'bad: a @generates path absent from the ignore list fails' \
    "${DECLARING_SCRIPTS}" "${FIXTURES}/bad-generates-missing.yml" 1 \
    'declares @generates docs/alpha.md, which is absent from the IGNORED list'

  # (d) BAD: rule 2. A file that merely carries a generated block is
  # ignored wholesale, so hand edits to the prose around the block stop
  # counting toward PR size.
  expect 'bad: a @generates-block path on the ignore list fails' \
    "${DECLARING_SCRIPTS}" "${FIXTURES}/bad-generates-block-ignored.yml" 1 \
    'declares @generates-block docs/beta.md, which is on the IGNORED list'

  # (e) BAD: rule 3. An entry no generator claims — the shape that hides
  # a hand-authored file's every edit behind a zero size contribution.
  expect 'bad: an ignore-list entry no generator declares fails' \
    "${DECLARING_SCRIPTS}" "${FIXTURES}/bad-undeclared-entry.yml" 1 \
    'IGNORED lists docs/handwritten.md, which no script declares'

  # (f) TOOLING: a scan root whose scripts declare nothing. Zero
  # declarations makes rule 1 and rule 2 vacuous and rule 3 maximally
  # loud, so the verdict must be could-not-run rather than a clean pass
  # or a pile of findings about a set that was never read.
  expect 'tooling: zero declarations is a could-not-run' \
    "${SILENT_SCRIPTS}" "${FIXTURES}/no-declarations.yml" 2 \
    'read 0 generator declaration(s)'

  # (g) TOOLING: ...and the documented override suppresses it, for a
  # scan root that deliberately declares nothing.
  expect 'tooling: the empty-scan override suppresses the breadth guard' \
    "${SILENT_SCRIPTS}" "${FIXTURES}/no-declarations.yml" 0 '' 1

  # (h) TOOLING: no *.sh under the scan root at all. glob_into owns this
  # verdict — an unread scripts/ tree would otherwise read as a tree that
  # declares nothing.
  expect 'tooling: a scripts root holding no shell script is a could-not-run' \
    "${FIXTURES}" "${FIXTURES}/good.yml" 2 'matched 0 files'

  # (i) TOOLING: the workflow does not parse. An unparsable file yields
  # no ignore-list entries, which would otherwise score as a list that
  # ignores nothing — a finding about content the lint never read.
  expect 'tooling: an unparsable workflow is a could-not-run' \
    "${DECLARING_SCRIPTS}" "${work}/bad-malformed.yml" 2 \
    'could not evaluate'

  # (j) TOOLING: the workflow parses and runs the size-label action, but
  # the step carries no ignore list. Nothing to compare against, so no
  # declaration could ever be found missing from it.
  expect 'tooling: a size-label step with no ignore list is a could-not-run' \
    "${DECLARING_SCRIPTS}" "${FIXTURES}/bad-no-ignored.yml" 2 \
    'declares no IGNORED'

  # (k) TOOLING: no step runs the size-label action. The subject is
  # discovered by the action it runs, so a discovery predicate that
  # matches nothing must fail loud rather than vouch for a list it never
  # located.
  expect 'tooling: a workflow running no size-label action is a could-not-run' \
    "${DECLARING_SCRIPTS}" "${FIXTURES}/bad-no-size-step.yml" 2 \
    'found 0 step(s) running'

  # (l) TOOLING: the workflow is absent.
  expect 'tooling: an absent workflow is a could-not-run' \
    "${DECLARING_SCRIPTS}" "${FIXTURES}/no-such-workflow.yml" 2 \
    'not found or unreadable'

  # (n) TOOLING: a regular file the parser cannot read. `[[ -f ]]` is
  # satisfied by a mode-000 script, so the scan counts it and hands it to
  # the parser, which is the only place the read is attempted. Reporting
  # that as a tree whose scripts declare nothing would attribute every
  # ignore-list entry to no generator — a verdict about content never
  # read. The copy is made here rather than committed, because git tracks
  # only the execute bit.
  mkdir --parents -- "${work}/unreadable/scripts"
  cp -- "${DECLARING_SCRIPTS}"/*.sh "${work}/unreadable/scripts/"
  chmod 000 -- "${work}/unreadable/scripts/refresh-alpha.sh"
  expect 'tooling: an unreadable script under the scan root is a could-not-run' \
    "${work}/unreadable/scripts" "${FIXTURES}/good.yml" 2 \
    'could not read every shell script under'
  chmod 644 -- "${work}/unreadable/scripts/refresh-alpha.sh"

  # (o) KEY AS DATA: a job key is data, never expression text. Each key
  # below closes a quoted segment if spliced into a `yq` expression: it
  # would read the clean decoy job's list or none at all, or print an
  # environment variable or a file through `error()`. Read as data, every
  # one reports the undeclared entry its own job's list carries, which
  # each scenario names after itself.
  printf 'FILE_READ_MARK\n' >"${work}/probe.txt"
  local -a key_cases=(
    'reads-decoy' 'x" // .jobs."decoy'
    'reads-nothing' 'x" | select(false) | ."y'
    'reads-env' 'x" | error(strenv(PROBE)) | ."y'
    'reads-file' 'x" | error(load_str(strenv(PROBE_FILE))) | ."y'
    'quote' 'k"x'
    'backslash' 'k\x'
  )
  local i case_name key
  for ((i = 0; i < ${#key_cases[@]}; i += 2)); do
    case_name="${key_cases[i]}" key="${key_cases[i + 1]}"
    cat >"${work}/key-${case_name}.yml" <<EOF
name: key-${case_name}
on:
  workflow_dispatch: {}
jobs:
  '${key//\'/\'\'}':
    runs-on: ubuntu-latest
    steps:
      - uses: pascalgn/size-label-action@56b489b027932ec0cf60438a1a5f1a19c8fc71ff # v0.5.7
        env:
          IGNORED: "docs/alpha.md\ndocs/key-${case_name}.md"
  decoy:
    runs-on: ubuntu-latest
    steps:
      - uses: pascalgn/size-label-action@56b489b027932ec0cf60438a1a5f1a19c8fc71ff # v0.5.7
        env:
          IGNORED: "docs/alpha.md"
EOF
    local finding="${work}/key-${case_name}.yml: IGNORED lists docs/key-${case_name}.md, which no script declares with @generates and which is not one of this lint's exemptions; every hand edit to it counts as zero toward the PR size label"
    PROBE=PAYLOAD_RAN PROBE_FILE="${work}/probe.txt" expect "key as data: ${case_name}" \
      "${DECLARING_SCRIPTS}" "${work}/key-${case_name}.yml" 1 "${finding}" '' \
      "${finding}"$'\n1 size-label ignore-list violation(s)'
  done
  # A key is looked up by its exact text: `*` is no wildcard. Read as a
  # pattern, the first job's key would read its sibling's list as well,
  # and the run would count four entries instead of three.
  cat >"${work}/key-wildcard.yml" <<'EOF'
name: key-wildcard
on:
  workflow_dispatch: {}
jobs:
  'a*':
    runs-on: ubuntu-latest
    steps:
      - uses: pascalgn/size-label-action@56b489b027932ec0cf60438a1a5f1a19c8fc71ff # v0.5.7
        env:
          IGNORED: "docs/alpha.md\nCHANGELOG.md"
  ab:
    runs-on: ubuntu-latest
    steps:
      - uses: pascalgn/size-label-action@56b489b027932ec0cf60438a1a5f1a19c8fc71ff # v0.5.7
        env:
          IGNORED: "docs/alpha.md"
EOF
  expect 'key as data: wildcard' "${DECLARING_SCRIPTS}" "${work}/key-wildcard.yml" 0 '' '' '' \
    "check-size-label-ignores.sh: ok — 2 declaration(s) (1 @generates, 1 @generates-block) across 2 script(s) under ${DECLARING_SCRIPTS}, checked against 3 IGNORED entry(ies) in ${work}/key-wildcard.yml"

  # (p) A job keyed by an alias is looked up by the key the job list
  # prints, and a key written twice reads its last job.
  local size_step='      - uses: pascalgn/size-label-action@56b489b027932ec0cf60438a1a5f1a19c8fc71ff # v0.5.7'
  printf 'name: a\non:\n  workflow_dispatch: {}\nx-name: &ka named\njobs:\n  *ka :\n    steps:\n%s\n        env:\n          IGNORED: "docs/alpha.md\\ndocs/key-alias.md"\n' \
    "${size_step}" >"${work}/key-alias.yml"
  expect 'key as data: an alias key' "${DECLARING_SCRIPTS}" "${work}/key-alias.yml" 1 \
    "${work}/key-alias.yml: IGNORED lists docs/key-alias.md, which no script declares with @generates and which is not one of this lint's exemptions; every hand edit to it counts as zero toward the PR size label"
  printf 'name: a\non:\n  workflow_dispatch: {}\njobs:\n  size:\n    steps:\n%s\n        env:\n          IGNORED: "docs/alpha.md"\n  size:\n    steps:\n%s\n        env:\n          IGNORED: "docs/alpha.md\\ndocs/key-twice.md"\n' \
    "${size_step}" "${size_step}" >"${work}/key-twice.yml"
  expect 'key as data: a key written twice' "${DECLARING_SCRIPTS}" "${work}/key-twice.yml" 1 \
    "${work}/key-twice.yml: IGNORED lists docs/key-twice.md, which no script declares with @generates and which is not one of this lint's exemptions; every hand edit to it counts as zero toward the PR size label"

  # A job key the job list cannot carry is refused, never read as other
  # names or as none, and so is a merge key under `jobs:`.
  local refused='which GitHub Actions refuses'
  local size_body=$'    runs-on: ubuntu-latest\n    steps:\n%s\n        env:\n          IGNORED: "docs/alpha.md"\n'
  # shellcheck disable=SC2059 # size_body is the format
  printf 'name: a\non:\n  workflow_dispatch: {}\njobs:\n  "a\\nb":\n'"${size_body}" "${size_step}" >"${work}/key-line-break.yml"
  expect 'key refused: a line break' "${DECLARING_SCRIPTS}" "${work}/key-line-break.yml" 1 "${refused}"
  # shellcheck disable=SC2059
  printf 'name: a\non:\n  workflow_dispatch: {}\njobs:\n  "":\n'"${size_body}" "${size_step}" >"${work}/key-empty.yml"
  expect 'key refused: empty' "${DECLARING_SCRIPTS}" "${work}/key-empty.yml" 1 "${refused}"
  # shellcheck disable=SC2059
  printf 'name: a\non:\n  workflow_dispatch: {}\nx: &base\n  size:\n'"${size_body}"'jobs:\n  <<: *base\n' "${size_step}" >"${work}/key-merge.yml"
  expect 'key refused: a merge key under jobs' "${DECLARING_SCRIPTS}" "${work}/key-merge.yml" 1 "${refused}"
  # A merge list is read first mapping wins, so the job holds the size
  # step of the first mapping listed.
  # shellcheck disable=SC2059
  printf 'name: a\non:\n  workflow_dispatch: {}\np: &P\n  steps:\n    - uses: pascalgn/size-label-action@56b489b027932ec0cf60438a1a5f1a19c8fc71ff # v0.5.7\n      env:\n        IGNORED: "docs/alpha.md\\nCHANGELOG.md"\nq: &Q\n  steps:\n    - run: echo PAYLOAD_RAN\njobs:\n  size:\n    <<: [*P, *Q]\n' >"${work}/merge-list.yml"
  expect 'merge list: the first mapping wins' "${DECLARING_SCRIPTS}" "${work}/merge-list.yml" 0 ''

  # (m) LIVE: the real tree must satisfy the lint.
  expect 'live: real tree agrees' \
    "${REPO_ROOT}/scripts" "${REPO_ROOT}/.github/workflows/labeler.yml" 0 ''

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
