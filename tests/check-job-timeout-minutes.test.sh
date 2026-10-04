#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-job-timeout-minutes.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/job-timeout-minutes"

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
expect good-reusable.yml 0 ""
expect bad-missing.yml 1 "missing"
expect bad-zero.yml 1 "positive"
expect bad-non-int.yml 1 "unexpected shape"
expect bad-malformed.yml 1 "could not evaluate"
expect no-such-workflow.yml 2 'selected 0 of'

# The scenarios below build their workflow at run time, in a directory of
# their own: a formatter would rewrite a tagged or quoted node checked in
# as a fixture. Each asserts the whole of stderr.
BT='`'
readonly BT

# @description Run the script on one workflow built from printf-style
# text, and compare its exit code and the whole of its stderr. `%W` in
# the expected stderr stands for the workflow's path, which is numbered
# per scenario, so no two scenarios share an output. An expected stderr
# opening with `YQ_ERROR <token>` and a line break stands for one line of
# `yq`'s own, whose wording is not the lint's: it must start with
# `Error: ` and hold the token (a path or a tag, not a phrase).
# @arg $1 scenario name
# @arg $2 workflow text (printf format, no arguments)
# @arg $3 expected exit code
# @arg $4 expected stderr, `%W` for the workflow path
function expect_built() {
  local -r name="$1" text="$2" want_exit="$3" want="$4"
  local dir got_exit=0 got_stderr path
  SCENARIO_N=$((SCENARIO_N + 1))
  dir="$(mktemp --directory)"
  path="${dir}/wf-${SCENARIO_N}.yml"
  # shellcheck disable=SC2059 # the workflow text is the format
  printf "${text}" >"${path}"
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${dir}" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  local expected="${want//%W/${path}}"
  rm --recursive --force -- "${dir}"
  if [[ ${expected} == 'YQ_ERROR '* ]]; then
    local token="${expected%%$'\n'*}"
    token="${token#YQ_ERROR }"
    expected="${expected#*$'\n'}"
    if [[ ${got_stderr%%$'\n'*} != 'Error: '*"${token}"* ]]; then
      printf 'FAIL %s: stderr does not open with a line of yq'"'"'s own holding %q\n  got: %q\n' "${name}" "${token}" "${got_stderr}" >&2
      return 1
    fi
    got_stderr="${got_stderr#*$'\n'}"
  fi
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' "${name}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ ${got_stderr} != "${expected}" ]]; then
    printf 'FAIL %s: stderr\n  got:  %q\n  want: %q\n' "${name}" "${got_stderr}" "${expected}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${name}"
}
SCENARIO_N=0

# @description A scenario whose job passes: a sentinel job with no
# timeout follows it, so the run ends in that one finding alone, which
# shows the scan reached the rows. Each passing scenario has a failing
# twin reached the same way, written first of two jobs and followed by a
# passing one, which shows the job itself is read wherever it sits.
# @arg $1 scenario name
# @arg $2 workflow text ending in its jobs: block (printf format)
function expect_passes() {
  local -r sentinel="sentinel$((SCENARIO_N + 1))"
  expect_built "$1" "$2""  ${sentinel}:\\n    runs-on: x\\n" 1 \
    "%W: job ${sentinel} missing ${BT}timeout-minutes${BT} (default is 6h; declare an explicit value)
${ONE_BAD}"
}

readonly ONE_BAD='1 job(s) missing or invalid timeout-minutes'
readonly JOB_HEAD='on: push\njobs:\n  a:\n    runs-on: x\n'

# A value is compared as a number only once it is decimal digits, so a
# value bash would read as an expression never reaches arithmetic. The
# marker is inert: it records whether a command in the value ran.
marker_dir="$(mktemp --directory)"
readonly MARKER="${marker_dir}/PAYLOAD_RAN"
# shellcheck disable=SC2016 # the command substitution is the payload, kept literal
expect_built 'an integer-tagged value holding a command substitution is not evaluated' \
  "${JOB_HEAD}"'    timeout-minutes: !!int "failed[$(touch '"${MARKER}"')]"\n' 1 \
  "%W: job a timeout-minutes has unexpected shape (kind=scalar, tag=\"!!int\", value=\"failed[\$(touch ${MARKER})]\"); expected an integer in decimal digits
${ONE_BAD}"
if [[ -e ${MARKER} ]]; then
  printf 'FAIL the command in the timeout-minutes value ran\n' >&2
  exit 1
fi
rm --recursive --force -- "${marker_dir}"
printf 'OK   the command in the timeout-minutes value did not run\n'

expect_built 'an integer-tagged map is a finding' \
  "${JOB_HEAD}"'    timeout-minutes: !!int {a: 1}\n' 1 \
  "%W: job a timeout-minutes has unexpected shape (kind=map, tag=\"!!int\", value=\"!!int {a: 1}\"); expected an integer in decimal digits
${ONE_BAD}"
expect_built 'an integer-tagged list is a finding' \
  "${JOB_HEAD}"'    timeout-minutes: !!int [5]\n' 1 \
  "%W: job a timeout-minutes has unexpected shape (kind=seq, tag=\"!!int\", value=\"!!int [5]\"); expected an integer in decimal digits
${ONE_BAD}"
expect_built 'an integer-tagged word is a finding, not an unset variable' \
  "${JOB_HEAD}"'    timeout-minutes: !!int a\n' 1 \
  "%W: job a timeout-minutes has unexpected shape (kind=scalar, tag=\"!!int\", value=\"a\"); expected an integer in decimal digits
${ONE_BAD}"
expect_built 'an integer-tagged value holding a line break is read whole' \
  "${JOB_HEAD}"'    timeout-minutes: !!int "1\\nb|!!str"\n' 1 \
  "%W: job a timeout-minutes has unexpected shape (kind=scalar, tag=\"!!int\", value=\"1\\nb|!!str\"); expected an integer in decimal digits
${ONE_BAD}"
expect_built 'a hexadecimal integer is a finding' \
  "${JOB_HEAD}"'    timeout-minutes: 0x10\n' 1 \
  "%W: job a timeout-minutes has unexpected shape (kind=scalar, tag=\"!!int\", value=\"0x10\"); expected an integer in decimal digits
${ONE_BAD}"
expect_built 'a custom-tagged integer is a finding' \
  "${JOB_HEAD}"'    timeout-minutes: !x 5\n' 1 \
  "%W: job a timeout-minutes has unexpected shape (kind=scalar, tag=\"!x\", value=\"5\"); expected an integer in decimal digits
${ONE_BAD}"
expect_built 'a key with no value is a missing one' \
  'on: push\njobs:\n  nokey:\n    runs-on: x\n    timeout-minutes:\n' 1 \
  "%W: job nokey missing ${BT}timeout-minutes${BT} (default is 6h; declare an explicit value)
${ONE_BAD}"
expect_passes 'an integer-tagged value with a leading zero is read in decimal' \
  "${JOB_HEAD}"'    timeout-minutes: !!int "09"\n'
expect_built 'an integer-tagged value of zeros is not positive' \
  'on: push\njobs:\n  tagzero:\n    runs-on: x\n    timeout-minutes: !!int "00"\n  after:\n    runs-on: x\n    timeout-minutes: 5\n' 1 \
  "%W: job tagzero timeout-minutes must be positive (got 00)
${ONE_BAD}"
expect_built 'zeros only is not positive' \
  "${JOB_HEAD}"'    timeout-minutes: 00\n' 1 \
  "%W: job a timeout-minutes must be positive (got 00)
${ONE_BAD}"
expect_passes 'a value written as an alias is read through it' \
  'x-t: &t 7\n'"${JOB_HEAD}"'    timeout-minutes: *t\n'
expect_built 'a value written as an alias of zero is read through it' \
  'x-t: &t 0\non: push\njobs:\n  zalias:\n    runs-on: x\n    timeout-minutes: *t\n  after:\n    runs-on: x\n    timeout-minutes: 5\n' 1 \
  "%W: job zalias timeout-minutes must be positive (got 0)
${ONE_BAD}"
expect_passes 'a job written as an alias is read through it' \
  'x-t: &t 7\nx-j: &j {runs-on: x, timeout-minutes: *t}\non: push\njobs:\n  a: *j\n'
expect_built 'a job written as an alias of a zero timeout is read through it' \
  'x-t: &t 000\nx-j: &j {runs-on: x, timeout-minutes: *t}\non: push\njobs:\n  jalias: *j\n  after:\n    runs-on: x\n    timeout-minutes: 5\n' 1 \
  "%W: job jalias timeout-minutes must be positive (got 000)
${ONE_BAD}"

# A job is a reusable-workflow call only when its uses: is a string.
expect_built 'a uses: list carrying the string tag is no reusable-workflow call' \
  'on: push\njobs:\n  strlist:\n    uses: !!str [a]\n' 1 \
  "%W: job strlist missing ${BT}timeout-minutes${BT} (default is 6h; declare an explicit value)
${ONE_BAD}"
expect_passes 'a uses: written as an alias is read through it' \
  'x-u: &u o/r/.github/workflows/x.yml@v1\non: push\njobs:\n  a:\n    uses: *u\n'
expect_built 'a uses: written as an alias of a list is no reusable-workflow call' \
  'x-u: &u [o/r/.github/workflows/x.yml@v1]\non: push\njobs:\n  ualias:\n    uses: *u\n  after:\n    runs-on: x\n    timeout-minutes: 5\n' 1 \
  "%W: job ualias missing ${BT}timeout-minutes${BT} (default is 6h; declare an explicit value)
${ONE_BAD}"

# A tag is free text: a verbatim tag decodes %7C to a pipe, which must
# not split the value's fields.
expect_built 'a tag rendering pipes is printed whole' \
  "${JOB_HEAD}"'    timeout-minutes: !<tag:x%%7C5%%7Cy> 5\n' 1 \
  "%W: job a timeout-minutes has unexpected shape (kind=scalar, tag=\"tag:x|5|y\", value=\"5\"); expected an integer in decimal digits
${ONE_BAD}"
expect_built 'a uses: tag rendering a line break is no reusable-workflow call' \
  'on: push\njobs:\n  verbatim:\n    uses: !<tag:yaml.org,2002:str%%0Ax> o/r/.github/workflows/x.yml@v1\n' 1 \
  "%W: job verbatim missing ${BT}timeout-minutes${BT} (default is 6h; declare an explicit value)
${ONE_BAD}"

# A job id is the one raw field of a row, so one that is not a scalar,
# is empty, or holds a tab, a line break or a NUL could forge, split or
# garble it, and is refused, naming the first such id. A pipe cannot.
# An id written as an alias is read through it.
readonly ODD_A='jobs: holds a job id that is not a scalar, is empty, or holds a tab, a line break or a NUL, which GitHub Actions refuses; its jobs are not read (first: '
readonly ODD_B=')'
expect_built 'a job id written as an alias is read through it' \
  'x-k: &k idalias\non: push\njobs:\n  *k :\n    runs-on: x\n' 1 \
  "%W: job idalias missing ${BT}timeout-minutes${BT} (default is 6h; declare an explicit value)
${ONE_BAD}"
expect_built 'a job id that is a list is refused' \
  'on: push\njobs:\n  ? [a]\n  : {runs-on: x}\n' 1 \
  "%W: ${ODD_A}kind=seq, id=\"[a]\"${ODD_B}
${ONE_BAD}"
expect_built 'a job id written as an alias of a list is refused' \
  'x-k: &k [b, c]\non: push\njobs:\n  *k : {runs-on: x}\n' 1 \
  "%W: ${ODD_A}kind=seq, id=\"[b, c]\"${ODD_B}
${ONE_BAD}"
expect_built 'a job id holding a pipe is read as written' \
  'on: push\njobs:\n  "a|!!str":\n    runs-on: x\n' 1 \
  "%W: job a\\|\\!\\!str missing ${BT}timeout-minutes${BT} (default is 6h; declare an explicit value)
${ONE_BAD}"
expect_built 'an empty job id is refused' \
  'on: push\njobs:\n  "":\n    runs-on: x\n' 1 \
  "%W: ${ODD_A}kind=scalar, id=\"\"${ODD_B}
${ONE_BAD}"
expect_built 'a job id holding a tab is refused' \
  'on: push\njobs:\n  "a\\tb":\n    runs-on: x\n    timeout-minutes: 5\n' 1 \
  "%W: ${ODD_A}kind=scalar, id=\"a\\tb\"${ODD_B}
${ONE_BAD}"
expect_built 'a job id holding a line break in a second document is refused' \
  'on: push\njobs:\n  a:\n    runs-on: x\n    timeout-minutes: 5\n---\non: push\njobs:\n  "b\\nc":\n    runs-on: x\n    timeout-minutes: 5\n' 1 \
  "%W: ${ODD_A}kind=scalar, id=\"b\\nc\"${ODD_B}
${ONE_BAD}"
expect_built 'the first document holding an odd job id is the one named' \
  'on: push\njobs:\n  "f\\tg":\n    runs-on: x\n---\non: push\njobs:\n  "h\\ti":\n    runs-on: x\n' 1 \
  "%W: ${ODD_A}kind=scalar, id=\"f\\tg\"${ODD_B}
${ONE_BAD}"

# A workflow that does not parse fails the first read, once.
expect_built 'an unparsable workflow is one finding against the file' \
  'on: push\njobs: [a: b\n' 1 \
  "YQ_ERROR bad file
%W: could not evaluate workflow with yq (malformed?)
${ONE_BAD}"

expect_built 'a job id holding a NUL is refused' \
  'on: push\njobs:\n  "a\\0b":\n    runs-on: x\n    timeout-minutes: 5\n' 1 \
  "%W: ${ODD_A}kind=scalar, id=\"a\\u0000b\"${ODD_B}
${ONE_BAD}"

# jobs: written as an alias is read through it, and a second document's
# jobs are read as rows of their own.
expect_built 'a jobs: alias of a map lacking a timeout names its job' \
  'x-j: &j {aliased: {runs-on: x}}\non: push\njobs: *j\n' 1 \
  "%W: job aliased missing ${BT}timeout-minutes${BT} (default is 6h; declare an explicit value)
${ONE_BAD}"
expect_built 'a jobs: alias holding a job id with a tab is refused' \
  'x-j: &j {"d\\te": {runs-on: x}}\non: push\njobs: *j\n' 1 \
  "%W: ${ODD_A}kind=scalar, id=\"d\\te\"${ODD_B}
${ONE_BAD}"
expect_built 'a null jobs: in a later document has no ids to test' \
  'on: push\njobs:\n  first:\n    runs-on: x\n---\non: push\njobs:\n' 1 \
  "%W: job first missing ${BT}timeout-minutes${BT} (default is 6h; declare an explicit value)
${ONE_BAD}"
expect_built 'a second document is read as jobs, with no separator row' \
  'on: push\njobs:\n  a:\n    runs-on: x\n    timeout-minutes: 5\n---\non: push\njobs:\n  second:\n    runs-on: x\n' 1 \
  "%W: job second missing ${BT}timeout-minutes${BT} (default is 6h; declare an explicit value)
${ONE_BAD}"

# The job read fails on the workflow's own content (a jobs: that is not
# a map), which stays a finding against the file.
expect_built 'a jobs: yq cannot list is a finding against the file' \
  'on: push\njobs: 5\n' 1 \
  "YQ_ERROR !!int
%W: could not evaluate workflow with yq (malformed?)
${ONE_BAD}"

# A row with a field missing cannot be read, which is a finding rather
# than a pass. yq prints every field, so a stub stands in for one that
# does not: it answers the job read with a row holding only an id.
stub_dir="$(mktemp --directory)"
real_yq="$(command -v yq)"
printf '#!/usr/bin/env bash\ncase "$*" in *to_entries*) printf "a\\n"; exit 0 ;; esac\nexec %q "$@"\n' \
  "${real_yq}" >"${stub_dir}/yq"
chmod +x -- "${stub_dir}/yq"
PATH="${stub_dir}:${PATH}" expect_built 'a row missing its fields is a finding' \
  "${JOB_HEAD}"'    timeout-minutes: 5\n' 1 \
  "%W: job a: cannot read its uses: and timeout-minutes:
${ONE_BAD}"
# The same with every field present but the value's text: the job is
# reported once, not also as missing.
printf '#!/usr/bin/env bash\ncase "$*" in *to_entries*) printf "b\\tfalse\\tnone\\t-\\t\\"\\"\\n"; exit 0 ;; esac\nexec %q "$@"\n' \
  "${real_yq}" >"${stub_dir}/yq"
PATH="${stub_dir}:${PATH}" expect_built 'a row missing only its last field is a finding' \
  "${JOB_HEAD}"'    timeout-minutes: 5\n' 1 \
  "%W: job b: cannot read its uses: and timeout-minutes:
${ONE_BAD}"
rm --recursive --force -- "${stub_dir}"

printf 'all tests passed\n'
