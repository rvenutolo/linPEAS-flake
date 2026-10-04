#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-upload-artifact-strict.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/upload-artifact-strict"

function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${FIXTURES}" \
    WORKFLOW_FILE_FILTER="${fixture}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' "${fixture}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' "${fixture}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${fixture}"
}

expect good.yml 0 ""
expect good-no-upload.yml 0 ""
expect bad-missing.yml 1 "missing"
expect bad-warn.yml 1 "if-no-files-found: warn"
expect bad-ignore.yml 1 "if-no-files-found: ignore"
expect bad-malformed.yml 1 "could not evaluate"
expect no-such-workflow.yml 2 'selected 0 of'

# The scenarios below build their workflow at run time: a formatter
# would rewrite a tagged or quoted node checked in as a fixture. Each
# writes a numbered file and asserts the whole of stderr.
BT='`'
readonly BT

# @description Run the script on one built workflow and compare the exit
# code and the whole of stderr; `%W` in the expected stderr stands for
# the workflow path.
# @arg $1 scenario name
# @arg $2 workflow text (printf format, no arguments)
# @arg $3 expected exit code
# @arg $4 expected stderr
function expect_built() {
  local -r name="$1" text="$2" want_exit="$3" want="$4"
  local dir got_exit=0 got_stderr path expected
  SCENARIO_N=$((SCENARIO_N + 1))
  dir="$(mktemp --directory)"
  path="${dir}/wf-${SCENARIO_N}.yml"
  # shellcheck disable=SC2059 # the workflow text is the format
  printf "${text}" >"${path}"
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${dir}" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  expected="${want//%W/${path}}"
  rm --recursive --force -- "${dir}"
  if [[ ${got_exit} != "${want_exit}" || ${got_stderr} != "${expected}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  got:  %q\n  want: %q\n' \
      "${name}" "${got_exit}" "${want_exit}" "${got_stderr}" "${expected}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${name}"
}
SCENARIO_N=0
readonly ONE="1 actions/upload-artifact step(s) missing strict ${BT}if-no-files-found: error${BT}"
expect_built 'a value holding a line break is compared whole' \
  'on: push\njobs:\n  nl:\n    steps:\n      - uses: actions/upload-artifact@abc\n        with:\n          if-no-files-found: "error\\n"\n      - uses: actions/upload-artifact@abc\n        with:\n          if-no-files-found: error\n' 1 \
  "%W: job nl step[0] actions/upload-artifact has ${BT}if-no-files-found: \\\"error\\\\n\\\"${BT}; must be ${BT}error${BT}
${ONE}"
expect_built 'a value of a tag of its own is told apart by its tag' \
  'on: push\njobs:\n  xtag:\n    steps:\n      - uses: actions/upload-artifact@abc\n        with:\n          if-no-files-found: !x error\n      - uses: actions/upload-artifact@abc\n        with:\n          if-no-files-found: error\n' 1 \
  "%W: job xtag step[0] actions/upload-artifact if-no-files-found has unexpected shape (kind=scalar, tag=\"!x\", value=\"error\"); must be string \"error\"
${ONE}"
expect_built 'a list carrying the string tag is no value' \
  'on: push\njobs:\n  strlist:\n    steps:\n      - uses: actions/upload-artifact@abc\n        with:\n          if-no-files-found: !!str [a]\n      - uses: actions/upload-artifact@abc\n        with:\n          if-no-files-found: error\n' 1 \
  "%W: job strlist step[0] actions/upload-artifact if-no-files-found has unexpected shape (kind=seq, tag=\"!!str\", value=\"\"); must be string \"error\"
${ONE}"
expect_built 'an empty scalar carrying the map tag is no value' \
  'on: push\njobs:\n  mapempty:\n    steps:\n      - uses: actions/upload-artifact@abc\n        with:\n          if-no-files-found: !!map ''\n      - uses: actions/upload-artifact@abc\n        with:\n          if-no-files-found: error\n' 1 \
  "%W: job mapempty step[0] actions/upload-artifact if-no-files-found has unexpected shape (kind=scalar, tag=\"!!map\", value=\"\"); must be string \"error\"
${ONE}"
expect_built 'a tag rendering pipes is printed whole' \
  'on: push\njobs:\n  pipetag:\n    steps:\n      - uses: actions/upload-artifact@abc\n        with:\n          if-no-files-found: !<tag:x%%7Cerror> error\n      - uses: actions/upload-artifact@abc\n        with:\n          if-no-files-found: error\n' 1 \
  "%W: job pipetag step[0] actions/upload-artifact if-no-files-found has unexpected shape (kind=scalar, tag=\"tag:x|error\", value=\"error\"); must be string \"error\"
${ONE}"
expect_built 'a with: that is a list is no map' \
  'on: push\njobs:\n  withlist:\n    steps:\n      - uses: actions/upload-artifact@abc\n        with: !!str [a]\n      - uses: actions/upload-artifact@abc\n        with:\n          if-no-files-found: error\n' 1 \
  "%W: job withlist step[0] actions/upload-artifact with: has unexpected shape (kind=seq, tag=\"!!str\", value=\"\"); must be a map holding if-no-files-found: error
${ONE}"
expect_built 'a with: that is a string is no map' \
  'on: push\njobs:\n  withstr:\n    steps:\n      - uses: actions/upload-artifact@abc\n        with: hello\n      - uses: actions/upload-artifact@abc\n        with:\n          if-no-files-found: error\n' 1 \
  "%W: job withstr step[0] actions/upload-artifact with: has unexpected shape (kind=scalar, tag=\"!!str\", value=\"hello\"); must be a map holding if-no-files-found: error
${ONE}"
expect_built 'a with: map carrying a tag of its own is read' \
  'on: push\njobs:\n  withx:\n    steps:\n      - uses: actions/upload-artifact@abc\n        with: !x {if-no-files-found: error}\n      - uses: actions/upload-artifact@abc\n' 1 \
  "%W: job withx step[1] actions/upload-artifact missing ${BT}with.if-no-files-found: error${BT}
${ONE}"
expect_built 'a with: map carrying a tag of its own holding a bad value is read' \
  'on: push\njobs:\n  withxbad:\n    steps:\n      - uses: actions/upload-artifact@abc\n        with: !x {if-no-files-found: warn}\n      - uses: actions/upload-artifact@abc\n        with:\n          if-no-files-found: error\n' 1 \
  "%W: job withxbad step[0] actions/upload-artifact has ${BT}if-no-files-found: warn${BT}; must be ${BT}error${BT}
${ONE}"
expect_built 'a value written as an alias is read through it' \
  'x-v: &v error\non: push\njobs:\n  valias:\n    steps:\n      - uses: actions/upload-artifact@abc\n        with:\n          if-no-files-found: *v\n      - uses: actions/upload-artifact@abc\n' 1 \
  "%W: job valias step[1] actions/upload-artifact missing ${BT}with.if-no-files-found: error${BT}
${ONE}"
expect_built 'a value written as an alias of a bad value is read through it' \
  'x-v: &v warn\non: push\njobs:\n  valiasbad:\n    steps:\n      - uses: actions/upload-artifact@abc\n        with:\n          if-no-files-found: *v\n      - uses: actions/upload-artifact@abc\n        with:\n          if-no-files-found: error\n' 1 \
  "%W: job valiasbad step[0] actions/upload-artifact has ${BT}if-no-files-found: warn${BT}; must be ${BT}error${BT}
${ONE}"
expect_built 'a with: written as an alias is read through it' \
  'x-w: &w {if-no-files-found: error}\non: push\njobs:\n  walias:\n    steps:\n      - uses: actions/upload-artifact@abc\n        with: *w\n      - uses: actions/upload-artifact@abc\n' 1 \
  "%W: job walias step[1] actions/upload-artifact missing ${BT}with.if-no-files-found: error${BT}
${ONE}"
expect_built 'a with: alias holding an alias of a bad value is read through both' \
  'x-v: &v warn\nx-w: &w {if-no-files-found: *v}\non: push\njobs:\n  wnested:\n    steps:\n      - uses: actions/upload-artifact@abc\n        with: *w\n      - uses: actions/upload-artifact@abc\n        with:\n          if-no-files-found: error\n' 1 \
  "%W: job wnested step[0] actions/upload-artifact has ${BT}if-no-files-found: warn${BT}; must be ${BT}error${BT}
${ONE}"
expect_built 'a step written as an alias is read through it' \
  'x-s: &s {uses: actions/upload-artifact@abc, with: {if-no-files-found: warn}}\non: push\njobs:\n  salias:\n    steps:\n      - *s\n      - uses: actions/upload-artifact@abc\n        with:\n          if-no-files-found: error\n' 1 \
  "%W: job salias step[0] actions/upload-artifact has ${BT}if-no-files-found: warn${BT}; must be ${BT}error${BT}
${ONE}"
expect_built 'a job written as an alias is read through it' \
  'x-j: &j {steps: [{uses: actions/upload-artifact@abc, with: {if-no-files-found: warn}}]}\non: push\njobs:\n  jalias: *j\n' 1 \
  "%W: job jalias step[0] actions/upload-artifact has ${BT}if-no-files-found: warn${BT}; must be ${BT}error${BT}
${ONE}"
expect_built 'jobs: written as an alias is read through it' \
  'x-js: &js {jsalias: {steps: [{uses: actions/upload-artifact@abc, with: {if-no-files-found: warn}}]}}\non: push\njobs: *js\n' 1 \
  "%W: job jsalias step[0] actions/upload-artifact has ${BT}if-no-files-found: warn${BT}; must be ${BT}error${BT}
${ONE}"
expect_built 'a second document is read as jobs, with no separator row' \
  'on: push\njobs:\n  first:\n    steps:\n      - uses: actions/upload-artifact@abc\n        with:\n          if-no-files-found: error\n---\non: push\njobs:\n  second:\n    steps:\n      - uses: actions/upload-artifact@abc\n        with:\n          if-no-files-found: warn\n' 1 \
  "%W: job second step[0] actions/upload-artifact has ${BT}if-no-files-found: warn${BT}; must be ${BT}error${BT}
${ONE}"
readonly ODD='jobs: holds a job id that is not a string, is empty, or holds a tab, a line break or a NUL, which GitHub Actions refuses; its jobs are not read (first: '
expect_built 'a job id holding a tab is refused' \
  'on: push\njobs:\n  "a\\tb":\n    steps:\n      - uses: actions/upload-artifact@abc\n        with:\n          if-no-files-found: warn\n' 1 \
  "%W: ${ODD}kind=scalar, id=\"a\\tb\")
${ONE}"
expect_built 'a job id that is a list is refused' \
  'on: push\njobs:\n  ? [a]\n  : {steps: [{uses: actions/upload-artifact@abc}]}\n' 1 \
  "%W: ${ODD}kind=seq, id=\"[a]\")
${ONE}"
expect_built 'an empty job id is refused' \
  'on: push\njobs:\n  "":\n    steps:\n      - uses: actions/upload-artifact@abc\n        with:\n          if-no-files-found: warn\n' 1 \
  "%W: ${ODD}kind=scalar, id=\"\")
${ONE}"

printf 'all tests passed\n'
