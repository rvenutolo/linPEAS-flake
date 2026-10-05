#!/usr/bin/env bash
# tests/check-regex-range-ascii.test.sh — proves the lint reports a range
# between ASCII letters or digits in a bash [[ =~ ]] regex, read directly
# or through same-file assignments up to three levels, unless the test runs
# under a C locale; that it reads scripts/, scripts/lib/ and tests/; that it
# leaves classes, escaped brackets, glob tests and byte ranges alone; and
# that a file shfmt cannot parse, an empty scan set and an absent shfmt
# are a could-not-run. Every tree is built at run time.
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-regex-range-ascii.sh"

failures=0
work="$(mktemp --directory)"
trap 'rm --recursive --force -- "${work}"' EXIT

# @description Print the lint's closing advice for a count of findings,
# with the blank line that sets it off from them.
# @arg $1 finding count
function footer() {
  printf '\n\n%d regex range(s) follow the locale: under en_US.UTF-8 [0-9] also\nmatches digits such as U+0663 and U+FF15. Spell the class out\n([0123456789]) or match through ascii_match (scripts/lib/ascii-match.sh).' "$1"
}

# @description Write a file of the given lines under the scenario tree.
# @arg $1 scenario name  @arg $2 path under the tree  @arg $@ lines
function put() {
  local -r name="$1" rel="$2"
  shift 2
  mkdir --parents "${work}/${name}/${rel%/*}"
  printf '%s\n' "$@" >"${work}/${name}/${rel}"
}

# @description Run the lint over one scenario tree and compare exit code,
# the whole of stdout and the whole of stderr, each line's log timestamp
# stripped. DIR in the expected text stands for the tree.
# @arg $1 scenario name  @arg $2 expected exit  @arg $3 whole stdout
# @arg $4 whole stderr
function run_case() {
  local -r name="$1" want_exit="$2"
  local -r dir="${work}/${name}"
  local -r want_out="${3//DIR/${dir}}" want_err="${4//DIR/${dir}}"
  mkdir --parents "${dir}/scripts/lib" "${dir}/tests"
  local out="${work}/${name}.out" err="${work}/${name}.err" outcome="${work}/${name}.outcome"
  local rc=0
  env --unset=BASH_ENV ${CASE_ENV[@]+"${CASE_ENV[@]}"} \
    SCRIPTS_DIR_OVERRIDE="${dir}/scripts" TESTS_DIR_OVERRIDE="${dir}/tests" \
    "${SCRIPT}" >"${out}" 2>"${err}" || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${outcome}"
  local asserted="${want_err%%$'\n'*}"
  [[ -n ${asserted} ]] || asserted="${want_out}"
  harness_assert_record "${name}" "${asserted}" "${outcome}" "${out}" "${err}"
  local got_err
  got_err="$(sed --regexp-extended 's/^\[[^]]*\] //' -- "${err}")"
  if [[ ${rc} -eq ${want_exit} && "$(cat -- "${out}")" == "${want_out}" && ${got_err} == "${want_err}" ]]; then
    printf 'PASS: %s (exit %d)\n' "${name}" "${rc}"
  else
    printf 'FAIL: %s: expected exit %d, stdout %q, stderr %q; got exit %d, stdout %q, stderr %q\n' \
      "${name}" "${want_exit}" "${want_out}" "${want_err}" "${rc}" \
      "$(cat -- "${out}")" "${got_err}" >&2
    failures=$((failures + 1))
  fi
}

declare -a CASE_ENV=()

# shellcheck disable=SC2016 # every put line is file text, not an expansion
{
  put spelled-out scripts/a.sh '#!/usr/bin/env bash' '[[ $1 =~ ^[0123456789]+$ ]]'
  run_case spelled-out 0 'regex-range-ascii: ok — scanned 1 file(s), 1 =~ test(s), 0 with a regex in a variable, 0 under a C locale' ''

  put digit-range scripts/a.sh '#!/usr/bin/env bash' 'x=1' '[[ $1 =~ ^v[0-9]+$ ]]'
  run_case digit-range 1 '' "DIR/scripts/a.sh:3: regex range 0-9 follows the locale$(footer 1)"

  put hex-letter-range scripts/a.sh '#!/usr/bin/env bash' '[[ $1 =~ ^[a-f]{40}$ ]]'
  run_case hex-letter-range 1 '' "DIR/scripts/a.sh:2: regex range a-f follows the locale$(footer 1)"

  put identifier-range scripts/a.sh '#!/usr/bin/env bash' '[[ $1 =~ ^[_A-Za-z]$ ]]'
  run_case identifier-range 1 '' "DIR/scripts/a.sh:2: regex range A-Z follows the locale$(footer 1)"

  put leading-bracket scripts/a.sh '#!/usr/bin/env bash' '[[ $1 =~ []x-z] ]]'
  run_case leading-bracket 1 '' "DIR/scripts/a.sh:2: regex range x-z follows the locale$(footer 1)"

  put negated-range scripts/a.sh '#!/usr/bin/env bash' '[[ $1 =~ [^1-8] ]]'
  run_case negated-range 1 '' "DIR/scripts/a.sh:2: regex range 1-8 follows the locale$(footer 1)"

  put through-readonly scripts/a.sh '#!/usr/bin/env bash' "readonly RE='^[2-7]+\$'" '[[ $1 =~ ${RE} ]]'
  run_case through-readonly 1 '' "DIR/scripts/a.sh:3: regex range 2-7 (through RE) follows the locale$(footer 1)"

  put through-local scripts/a.sh '#!/usr/bin/env bash' 'f() {' "  local re='[b-y]'" '  [[ $1 =~ $re ]]' '}'
  run_case through-local 1 '' "DIR/scripts/a.sh:4: regex range b-y (through re) follows the locale$(footer 1)"

  put three-levels scripts/a.sh '#!/usr/bin/env bash' "C3='[3-6]'" 'B2="(${C3})"' 'A1="x${B2}"' '[[ $1 =~ ${A1} ]]'
  run_case three-levels 1 '' "DIR/scripts/a.sh:5: regex range 3-6 (through C3) follows the locale$(footer 1)"

  put four-levels scripts/a.sh '#!/usr/bin/env bash' "D4='[4-5]'" 'C3="${D4}"' 'B2="(${C3})"' 'A1="x${B2}"' '[[ $1 =~ ${A1} ]]'
  run_case four-levels 0 'regex-range-ascii: ok — scanned 1 file(s), 1 =~ test(s), 1 with a regex in a variable, 0 under a C locale' ''

  put local-c scripts/a.sh '#!/usr/bin/env bash' 'f() {' '  local LC_ALL=C' '  [[ $1 =~ [0-9] ]]' '}' 'g() {' '  local LC_ALL=C.UTF-8' '  [[ $1 =~ [a-z] ]]' '}'
  run_case local-c 0 'regex-range-ascii: ok — scanned 1 file(s), 2 =~ test(s), 0 with a regex in a variable, 2 under a C locale' ''

  put local-other-locale scripts/a.sh '#!/usr/bin/env bash' 'f() {' '  local LC_ALL=en_US.UTF-8' '  [[ $1 =~ [5-9] ]]' '}'
  run_case local-other-locale 1 '' "DIR/scripts/a.sh:4: regex range 5-9 follows the locale$(footer 1)"

  put c-in-other-function scripts/a.sh '#!/usr/bin/env bash' 'f() {' '  local LC_ALL=C' '}' 'g() {' '  [[ $1 =~ [6-9] ]]' '}'
  run_case c-in-other-function 1 '' "DIR/scripts/a.sh:6: regex range 6-9 follows the locale$(footer 1)"

  put export-c scripts/a.sh '#!/usr/bin/env bash' 'export LC_ALL=C' '[[ $1 =~ [0-9] ]]' '[[ $1 =~ [a-c] ]]' '[[ $1 =~ [d-e] ]]'
  run_case export-c 0 'regex-range-ascii: ok — scanned 1 file(s), 3 =~ test(s), 0 with a regex in a variable, 3 under a C locale' ''

  put not-ranges scripts/a.sh '#!/usr/bin/env bash' '[[ $1 =~ [[:digit:]][[:alpha:]] ]]' "readonly R='[^-&[:alnum:]_]'" '[[ $1 =~ ${R} ]]' \
    '[[ $1 =~ \[0-9] ]]' '[[ $1 =~ [a-] ]]' "[[ \$1 =~ \$'[\\x01-\\x1f]' ]]" '[[ $1 == [0-9] ]]' '[[ $1 =~ [=a=][.-.] ]]'
  run_case not-ranges 0 'regex-range-ascii: ok — scanned 1 file(s), 6 =~ test(s), 1 with a regex in a variable, 0 under a C locale' ''

  put argument-regex scripts/a.sh '#!/usr/bin/env bash' 'f() {' '  local -r re="$1"' '  [[ $2 =~ ${re} ]]' '  [[ $2 =~ $1 ]]' '}' "f '[0-9]' x"
  run_case argument-regex 0 'regex-range-ascii: ok — scanned 1 file(s), 2 =~ test(s), 1 with a regex in a variable, 0 under a C locale' ''

  put no-test scripts/a.sh '#!/usr/bin/env bash' "grep -E '[0-9]' x" '# [[ $1 =~ [0-9] ]] in a comment is text'
  put no-test scripts/b.sh '#!/usr/bin/env bash' "grep -E '[0-9]' y"
  run_case no-test 0 'regex-range-ascii: ok — scanned 2 file(s), 0 =~ test(s), 0 with a regex in a variable, 0 under a C locale' ''

  put lib-and-tests scripts/lib/l.sh '[[ $1 =~ [7-8] ]]'
  put lib-and-tests tests/t.test.sh '#!/usr/bin/env bash' '[[ $1 =~ [g-h] ]]'
  run_case lib-and-tests 1 '' "DIR/scripts/lib/l.sh:1: regex range 7-8 follows the locale
DIR/tests/t.test.sh:2: regex range g-h follows the locale$(footer 2)"

  put unparsable scripts/a.sh '#!/usr/bin/env bash' '[[ $1 =~ x' 'if then fi )'
  run_case unparsable 2 '' 'ERROR cannot parse DIR/scripts/a.sh'

  run_case empty-scan 2 '' "check-regex-range-ascii.sh: matched 0 files via scripts, script libraries and harnesses — a real tree cannot have an empty scan set; set LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate"

  # An absolute bash and a PATH holding no shfmt: the script is reached,
  # and its own guard is what fires.
  put no-shfmt scripts/a.sh '#!/usr/bin/env bash' '[[ $1 =~ [0-9] ]]'
  mkdir --parents "${work}/no-shfmt-bin"
  ln --symbolic -- "$(command -v jq)" "${work}/no-shfmt-bin/jq"
  ln --symbolic -- "$(command -v grep)" "${work}/no-shfmt-bin/grep"
  ln --symbolic -- "$(command -v bash)" "${work}/no-shfmt-bin/bash"
  CASE_ENV=("PATH=${work}/no-shfmt-bin")
  run_case no-shfmt 2 '' 'ERROR missing required tool: shfmt'
  CASE_ENV=()
}

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -ne 0 ]]; then
  printf '%d failure(s)\n' "${failures}" >&2
  exit 1
fi
