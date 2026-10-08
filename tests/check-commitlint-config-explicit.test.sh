#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-commitlint-config-explicit.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/commitlint-config-explicit"

function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(PATHS_OVERRIDE="${FIXTURES}/${fixture}" \
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

# Expected substrings avoid backticks on purpose: treefmt rewrites a
# double-quoted string holding them into single quotes, and shellcheck
# then reports SC2016 on the same line. Each substring below is still
# unique to the failure it names.
expect good/ci.yml 0 ""
expect no-with/ci.yml 1 "block; add"
expect no-configfile/ci.yml 1 "no non-empty"
expect missing-path/ci.yml 1 "does not exist"
expect extra-rule/ci.yml 1 "rules must be exactly"
expect extends-mismatch/ci.yml 1 "declare different"

# A workflow yq cannot parse must fail loud, not empty the scan silently.
expect bad-malformed/ci.yml 1 "could not evaluate"

# --- shapes of with: and configFile:, built at run time ---------------
# A formatter would rewrite a tagged or quoted node checked in as a
# fixture. Each scenario writes a numbered workflow beside the good
# fixture's two configs and asserts the whole of stderr.
BT='`'
readonly BT

# @description Run the script on one built workflow and compare the exit
# code and the whole of stderr; `%W` stands for the workflow path and
# `%D` for its directory.
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
  cp -- "${FIXTURES}/good/.commitlintrc.yml" "${FIXTURES}/good/.commitlintrc.merge.yml" "${dir}/"
  # shellcheck disable=SC2059 # the workflow text is the format
  printf "${text}" >"${path}"
  got_stderr="$(PATHS_OVERRIDE="${path}" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  expected="${want//%W/${path}}"
  expected="${expected//%D/${dir}}"
  rm --recursive --force -- "${dir}"
  if [[ ${got_exit} != "${want_exit}" || ${got_stderr} != "${expected}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  got:  %q\n  want: %q\n' \
      "${name}" "${got_exit}" "${want_exit}" "${got_stderr}" "${expected}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${name}"
}
SCENARIO_N=0
readonly ONE='1 commitlint config drift(s) found'
readonly HEAD=$'on: push\njobs:\n'
readonly NO_WITH="has no ${BT}with:${BT} block; add ${BT}with.configFile: <path>${BT} (an unset configFile silently falls back to a bundled preset)"
readonly NO_CFG="has no non-empty ${BT}with.configFile:${BT}; add one (an unset configFile silently falls back to a bundled preset)"
readonly BARE='      - uses: wagoid/commitlint-github-action@x\n'
readonly GOOD='      - uses: wagoid/commitlint-github-action@x\n        with: {configFile: .commitlintrc.yml}\n'

# @description A passing step, then a sentinel step with no with:, in a
# job named after the scenario: the run ends in the sentinel's finding.
# @arg $1 scenario name  @arg $2 text before on:  @arg $3 job id
# @arg $4 the passing step (printf format)
function expect_passes() {
  expect_built "$1" "$2${HEAD}  $3:\n    steps:\n$4${BARE}" 1 \
    "%W: job $3 step[1] wagoid/commitlint-github-action ${NO_WITH}
${ONE}"
}

# @description A failing step first, then a passing one.
# @arg $1 scenario name  @arg $2 text before on:  @arg $3 job id
# @arg $4 the failing step  @arg $5 its finding after "step[0] "
function expect_fails_first() {
  expect_built "$1" "$2${HEAD}  $3:\n    steps:\n$4${GOOD}" 1 \
    "%W: job $3 step[0] $5
${ONE}"
}

expect_passes 'a with: map carrying a tag of its own is read' '' withx \
  '      - uses: wagoid/commitlint-github-action@x\n        with: !x {configFile: .commitlintrc.yml}\n'
expect_fails_first 'a with: map carrying a tag of its own lacking configFile is read' '' withxbad \
  '      - uses: wagoid/commitlint-github-action@x\n        with: !x {other: 1}\n' "wagoid/commitlint-github-action ${NO_CFG}"
expect_fails_first 'a with: that is a list is no map' '' withlist \
  '      - uses: wagoid/commitlint-github-action@x\n        with: !!str [a]\n' \
  "wagoid/commitlint-github-action ${BT}with:${BT} has unexpected shape (kind=seq, tag=\"!!str\"); it must be a map holding ${BT}configFile: <path>${BT}"
expect_fails_first 'a with: that is a string is no map' '' withstr \
  '      - uses: wagoid/commitlint-github-action@x\n        with: hello\n' \
  "wagoid/commitlint-github-action ${BT}with:${BT} has unexpected shape (kind=scalar, tag=\"!!str\"); it must be a map holding ${BT}configFile: <path>${BT}"
expect_fails_first 'a configFile: that is a list is no path' '' cfglist \
  '      - uses: wagoid/commitlint-github-action@x\n        with: {configFile: [.commitlintrc.yml]}\n' \
  "wagoid/commitlint-github-action ${BT}configFile:${BT} has unexpected shape (kind=seq, tag=\"!!seq\", value=\"[.commitlintrc.yml]\"); it must be a path"
expect_fails_first 'a configFile: holding a line break names no file' '' cfgbreak \
  '      - uses: wagoid/commitlint-github-action@x\n        with: {configFile: ".commitlintrc.yml\\nx"}\n' \
  "${BT}configFile${BT} names \\\".commitlintrc.yml\\\\nx\\\", which does not exist at %D/\\\".commitlintrc.yml\\\\nx\\\""
expect_passes 'a with: written as an alias is read through it' 'x-w: &w {configFile: .commitlintrc.yml}\n' walias \
  '      - uses: wagoid/commitlint-github-action@x\n        with: *w\n'
expect_passes 'a configFile: written as an alias is read through it' 'x-c: &c .commitlintrc.yml\n' calias \
  '      - uses: wagoid/commitlint-github-action@x\n        with: {configFile: *c}\n'
expect_fails_first 'a configFile: written as an alias of an empty string is read through it' "x-c: &c ''\\n" caliasempty \
  '      - uses: wagoid/commitlint-github-action@x\n        with: {configFile: *c}\n' "wagoid/commitlint-github-action ${NO_CFG}"
expect_fails_first 'a step written as an alias is read through it' 'x-s: &s {uses: wagoid/commitlint-github-action@x}\n' salias \
  '      - *s\n' "wagoid/commitlint-github-action ${NO_WITH}"
expect_built 'a job written as an alias is read through it' \
  'x-j: &j {steps: [{uses: wagoid/commitlint-github-action@x}]}\n'"${HEAD}"'  jalias: *j\n' 1 \
  "%W: job jalias step[0] wagoid/commitlint-github-action ${NO_WITH}
${ONE}"
expect_built 'jobs: written as an alias is read through it' \
  'x-js: &js {jsalias: {steps: [{uses: wagoid/commitlint-github-action@x}]}}\non: push\njobs: *js\n' 1 \
  "%W: job jsalias step[0] wagoid/commitlint-github-action ${NO_WITH}
${ONE}"
expect_built 'a second document is read as jobs, with no separator row' \
  "${HEAD}"'  first:\n    steps:\n'"${GOOD}"'---\n'"${HEAD}"'  second:\n    steps:\n'"${BARE}" 1 \
  "%W: job second step[0] wagoid/commitlint-github-action ${NO_WITH}
${ONE}"
readonly ODD='jobs: holds a job id that is not a scalar, is empty, is a merge key, or holds a tab, a line break or a NUL, which GitHub Actions refuses; its jobs are not read (first: '
expect_built 'a job id holding a tab is refused' \
  "${HEAD}"'  "a\\tb":\n    steps:\n'"${BARE}" 1 \
  "%W: ${ODD}kind=scalar, id=\"a\\tb\")
${ONE}"
# A merge key under jobs: brings jobs in that the per-job read never reaches.
expect_built 'a merge key under jobs: is refused' \
  'base: &base {c: {runs-on: ubuntu-latest, steps: [{uses: wagoid/commitlint-github-action@b948419dd99f3fd78a6548d48f94e3df7f6bf3ed, with: {}}]}}\n'"${HEAD}"'  <<: *base\n' 1 \
  "%W: ${ODD}kind=scalar, id=\"<<\")
${ONE}"
# A merge list in a step gives the first mapping the win, as the YAML
# merge specification says; yq reads the last one unless told otherwise.
readonly MERGE_A='a: &a {uses: wagoid/commitlint-github-action@x, with: {configFile: .commitlintrc.yml}}\n'
readonly MERGE_B='b: &b {uses: wagoid/commitlint-github-action@x, with: {}}\n'
expect_built 'a merge list in a step is read first mapping wins: the step without configFile first is refused' \
  "${MERGE_A}${MERGE_B}${HEAD}"'  c:\n    steps:\n      - <<: [*b, *a]\n' 1 \
  "%W: job c step[0] wagoid/commitlint-github-action ${NO_CFG}
${ONE}"
expect_built 'a merge list in a step is read first mapping wins: the step with configFile first passes' \
  "${MERGE_A}${MERGE_B}${HEAD}"'  c:\n    steps:\n      - <<: [*a, *b]\n' 0 ''
expect_fails_first 'a configFile: list carrying the string tag is no path' '' cfgstrlist \
  '      - uses: wagoid/commitlint-github-action@x\n        with: {configFile: !!str [.commitlintrc.yml]}\n' \
  "wagoid/commitlint-github-action ${BT}configFile:${BT} has unexpected shape (kind=seq, tag=\"!!str\", value=\"\"); it must be a path"
expect_built 'a steps: that is not a list holds no step' \
  "${HEAD}"'  mapsteps:\n    steps: {0: {uses: wagoid/commitlint-github-action@x}}\n  after:\n    steps:\n'"${BARE}" 1 \
  "%W: job after step[0] wagoid/commitlint-github-action ${NO_WITH}
${ONE}"
expect_built 'an empty job id is refused' \
  "${HEAD}"'  "":\n    steps:\n'"${BARE}" 1 \
  "%W: ${ODD}kind=scalar, id=\"\")
${ONE}"
expect_fails_first 'a with: with no value is no with: block' '' withnull \
  '      - uses: wagoid/commitlint-github-action@x\n        with:\n' "wagoid/commitlint-github-action ${NO_WITH}"
# A chain five aliases deep: the job, its steps, a step, the step's
# uses: and with:, and the value. The job's two passes resolve the first
# two, and the step's three the rest.
expect_built 'a five-deep alias chain is read through' \
  'x-u: &u wagoid/commitlint-github-action@x\nx-v: &v ''\nx-w: &w {configFile: *v}\nx-s: &s {uses: *u, with: *w}\nx-l: &l [*s]\nx-j: &j {steps: *l}\non: push\njobs:\n  deep: *j\n' 1 \
  "%W: job deep step[0] wagoid/commitlint-github-action ${NO_CFG}
${ONE}"
expect_built 'a step alias whose uses: is an alias is read through both' \
  'x-u: &u wagoid/commitlint-github-action@x\nx-s: &s {uses: *u}\n'"${HEAD}"'  usesalias:\n    steps:\n      - *s\n' 1 \
  "%W: job usesalias step[0] wagoid/commitlint-github-action ${NO_WITH}
${ONE}"
expect_built 'a job id that is a list is refused' \
  "${HEAD}"'  ? [a]\n  : {steps: [{uses: wagoid/commitlint-github-action@x}]}\n' 1 \
  "%W: ${ODD}kind=seq, id=\"[a]\")
${ONE}"
# A commitlint config that does not parse is a file this lint could not
# read: yq exits 1 on it, and reporting that as the rule-set drift
# verdict would name rules nothing was ever read. The config is written
# at run time rather than kept in the tree, because the formatters
# refuse to touch unparsable YAML.
function expect_unparsable() {
  local dir got_exit=0 got_stderr
  dir="$(mktemp --directory)"
  : >"${dir}/ci.yml"
  cp -- "${FIXTURES}/good/.commitlintrc.yml" "${dir}/.commitlintrc.yml"
  printf 'rules: [\n' >"${dir}/.commitlintrc.merge.yml"
  got_stderr="$(PATHS_OVERRIDE="${dir}/ci.yml" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --recursive --force -- "${dir}"
  if [[ ${got_exit} != 2 || ${got_stderr} != *'cannot read .rules from'* ]]; then
    printf 'FAIL unparsable merge config: exit %s\n  stderr: %s\n' \
      "${got_exit}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   unparsable merge config is a tooling error\n'
}
expect_unparsable

# @description Drive the enumeration itself, not a fixture: with
# PATHS_OVERRIDE unset the script enumerates via `git ls-files`, and an
# unreadable index makes that producer exit 0 with no output. A status
# check cannot see that, so the empty scan set has to be the assertion.
# @arg $1 expected exit code  @arg $2 expected stderr substring
function expect_empty_scan() {
  local -r want_exit="$1" want_msg="$2"
  local got_exit=0 got_stderr index_dir
  index_dir="$(mktemp --directory)"
  got_stderr="$(cd "${REPO_ROOT}" &&
    GIT_INDEX_FILE="${index_dir}/absent.idx" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --recursive --force -- "${index_dir}"
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL empty-scan: exit %s, want %s\n  stderr: %s\n' "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL empty-scan: stderr missing %q\n  got: %s\n' "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   empty-scan\n'
}

expect_empty_scan 2 "enumerated 0 files via git ls-files"

printf 'all tests passed\n'
