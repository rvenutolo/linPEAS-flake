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
  if [[ ${USE_DEFAULT_DIRS} -eq 1 ]]; then
    (cd -- "${dir}" && env --unset=BASH_ENV --unset=SCRIPTS_DIR_OVERRIDE --unset=TESTS_DIR_OVERRIDE \
      ${CASE_ENV[@]+"${CASE_ENV[@]}"} "${SCRIPT}") >"${out}" 2>"${err}" || rc=$?
  else
    env --unset=BASH_ENV ${CASE_ENV[@]+"${CASE_ENV[@]}"} \
      SCRIPTS_DIR_OVERRIDE="${dir}/scripts" TESTS_DIR_OVERRIDE="${dir}/tests" \
      "${SCRIPT}" >"${out}" 2>"${err}" || rc=$?
  fi
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
USE_DEFAULT_DIRS=0

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

  put local-posix scripts/a.sh '#!/usr/bin/env bash' 'f() {' '  local LC_ALL=POSIX' '  [[ $1 =~ [8-9] ]]' '}'
  run_case local-posix 1 '' "DIR/scripts/a.sh:4: regex range 8-9 follows the locale$(footer 1)"

  put assignment-valued-like-operator scripts/a.sh '#!/usr/bin/env bash' 'x==~' '[[ $1 =~ x ]]' '[[ $1 =~ y ]]' '[[ $1 =~ z ]]' '[[ $1 =~ w ]]' '[[ $1 =~ v ]]'
  run_case assignment-valued-like-operator 0 'regex-range-ascii: ok — scanned 1 file(s), 5 =~ test(s), 0 with a regex in a variable, 0 under a C locale' ''

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

  put hyphen-text-outside-brackets scripts/a.sh '#!/usr/bin/env bash' '[[ $1 =~ ^id-ab-12$ ]]' '[[ $1 =~ x-y\[a-c\] ]]' '[[ $1 =~ ^p-q$ ]]' '[[ $1 =~ ^r-s$ ]]'
  run_case hyphen-text-outside-brackets 0 'regex-range-ascii: ok — scanned 1 file(s), 4 =~ test(s), 0 with a regex in a variable, 0 under a C locale' ''

  put unassigned-variable scripts/a.sh '#!/usr/bin/env bash' '[[ $1 =~ ${NEVER_SET} ]]' '[[ $1 =~ a ]]' '[[ $1 =~ b ]]' '[[ $1 =~ c ]]' \
    '[[ $1 =~ d ]]' '[[ $1 =~ e ]]' '[[ $1 =~ f ]]'
  run_case unassigned-variable 0 'regex-range-ascii: ok — scanned 1 file(s), 7 =~ test(s), 1 with a regex in a variable, 0 under a C locale' ''

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

  # Where the pair sits relative to what precedes it, and what the bracket
  # scanner skips.
  put escape-then-range scripts/a.sh '#!/usr/bin/env bash' '[[ $1 =~ ^v\.[0-9]+$ ]]'
  run_case escape-then-range 1 '' "DIR/scripts/a.sh:2: regex range 0-9 follows the locale$(footer 1)"

  put negated-close-first scripts/a.sh '#!/usr/bin/env bash' '[[ $1 =~ [^]a-z] ]]'
  run_case negated-close-first 1 '' "DIR/scripts/a.sh:2: regex range a-z follows the locale$(footer 1)"

  put range-after-class scripts/a.sh '#!/usr/bin/env bash' '[[ $1 =~ [[:alnum:]a-f] ]]' '[[ $1 =~ [[:xdigit:]b-g] ]]' \
    '[[ $1 =~ [[=a=]c-h] ]]' '[[ $1 =~ [[.a.]d-i] ]]' '[[ $1 =~ [[:alpha:][:digit:]e-j] ]]'
  run_case range-after-class 1 '' "DIR/scripts/a.sh:2: regex range a-f follows the locale
DIR/scripts/a.sh:3: regex range b-g follows the locale
DIR/scripts/a.sh:4: regex range c-h follows the locale
DIR/scripts/a.sh:5: regex range d-i follows the locale
DIR/scripts/a.sh:6: regex range e-j follows the locale$(footer 5)"

  put adjacent-brackets scripts/a.sh '#!/usr/bin/env bash' '[[ $1 =~ ^[x][0-9]$ ]]'
  run_case adjacent-brackets 1 '' "DIR/scripts/a.sh:2: regex range 0-9 follows the locale$(footer 1)"

  put punctuation-start scripts/a.sh '#!/usr/bin/env bash' '[[ $1 =~ [+-9] ]]' '[[ $1 =~ [0-+] ]]' '[[ $1 =~ [,-.] ]]'
  run_case punctuation-start 0 'regex-range-ascii: ok — scanned 1 file(s), 3 =~ test(s), 0 with a regex in a variable, 0 under a C locale' ''

  put test-over-two-lines scripts/a.sh '#!/usr/bin/env bash' '[[ $1' '  =~ ^v[0-9]$ ]]'
  run_case test-over-two-lines 1 '' "DIR/scripts/a.sh:2: regex range 0-9 follows the locale$(footer 1)"

  # How a regex held in a variable is followed.
  put assigned-twice scripts/a.sh '#!/usr/bin/env bash' "re='^[0-9]'" "re='^x'" '[[ $1 =~ $re ]]'
  run_case assigned-twice 1 '' "DIR/scripts/a.sh:4: regex range 0-9 (through re) follows the locale$(footer 1)"

  put assignments-read-apart scripts/a.sh '#!/usr/bin/env bash' 're=[x' 're=-9]' '[[ $1 =~ $re ]]' '[[ $1 =~ p ]]' '[[ $1 =~ q ]]'
  run_case assignments-read-apart 0 'regex-range-ascii: ok — scanned 1 file(s), 3 =~ test(s), 1 with a regex in a variable, 0 under a C locale' ''

  put range-kept-past-clean-variable scripts/a.sh '#!/usr/bin/env bash' "a='\$c'" "c='x'" "b='[0-9]'" '[[ $1 =~ ${a}${b} ]]'
  run_case range-kept-past-clean-variable 1 '' "DIR/scripts/a.sh:5: regex range 0-9 (through b) follows the locale$(footer 1)"

  put name-inside-earlier-name scripts/a.sh '#!/usr/bin/env bash' "abc='x'" "b='[0-9]'" '[[ $1 =~ ${abc}${b} ]]'
  run_case name-inside-earlier-name 1 '' "DIR/scripts/a.sh:4: regex range 0-9 (through b) follows the locale$(footer 1)"

  put bare-word-is-not-a-variable scripts/a.sh '#!/usr/bin/env bash' "v='[0-9]'" '[[ $1 =~ ^v+$ ]]' '[[ $1 =~ ^w+$ ]]'
  run_case bare-word-is-not-a-variable 0 'regex-range-ascii: ok — scanned 1 file(s), 2 =~ test(s), 0 with a regex in a variable, 0 under a C locale' ''

  put underscore-variable scripts/a.sh '#!/usr/bin/env bash' "_re='[0-9]'" '[[ $1 =~ $_re ]]'
  run_case underscore-variable 1 '' "DIR/scripts/a.sh:3: regex range 0-9 (through _re) follows the locale$(footer 1)"

  put underscore-variable-clean scripts/a.sh '#!/usr/bin/env bash' "_re='[0123456789]'" '[[ $1 =~ $_re ]]' '[[ $1 =~ r ]]' '[[ $1 =~ s ]]' '[[ $1 =~ t ]]'
  run_case underscore-variable-clean 0 'regex-range-ascii: ok — scanned 1 file(s), 4 =~ test(s), 1 with a regex in a variable, 0 under a C locale' ''

  # Byte offsets index the text only if the lint reads it as bytes, whatever
  # locale it is started under.
  put offsets-after-non-ascii-en_US scripts/a.sh '#!/usr/bin/env bash' '# é à ü ñ ß' '[[ $1 =~ ^v[0-9]$ ]]'
  put offsets-after-non-ascii-c-utf8 scripts/a.sh '#!/usr/bin/env bash' '# é à ü ñ ß' '[[ $1 =~ ^v[5-9]$ ]]'
  CASE_ENV=("LC_ALL=en_US.UTF-8")
  run_case offsets-after-non-ascii-en_US 1 '' "DIR/scripts/a.sh:3: regex range 0-9 follows the locale$(footer 1)"
  CASE_ENV=("LC_ALL=C.UTF-8")
  run_case offsets-after-non-ascii-c-utf8 1 '' "DIR/scripts/a.sh:3: regex range 5-9 follows the locale$(footer 1)"
  CASE_ENV=()

  # With no override the lint reads scripts/ and tests/ under the working
  # directory.
  put default-dirs scripts/a.sh '#!/usr/bin/env bash' '[[ $1 =~ [3-5] ]]'
  put default-dirs tests/t.test.sh '#!/usr/bin/env bash' '[[ $1 =~ [h-k] ]]'
  USE_DEFAULT_DIRS=1
  run_case default-dirs 1 '' "scripts/a.sh:2: regex range 3-5 follows the locale
tests/t.test.sh:2: regex range h-k follows the locale$(footer 2)"
  USE_DEFAULT_DIRS=0

  # A regex that a for-loop variable holds is read through its items.
  put for-loop-item scripts/a.sh '#!/usr/bin/env bash' 'for re in "[0-9]+" x; do' '  [[ $1 =~ $re ]]' 'done'
  run_case for-loop-item 1 '' "DIR/scripts/a.sh:3: regex range 0-9 (through re) follows the locale$(footer 1)"
  put for-loop-item-spelled scripts/a.sh '#!/usr/bin/env bash' 'for re in "[0123456789]+" x; do' '  [[ $1 =~ $re ]]' '  [[ $2 =~ $re ]]' 'done'
  run_case for-loop-item-spelled 0 'regex-range-ascii: ok — scanned 1 file(s), 2 =~ test(s), 2 with a regex in a variable, 0 under a C locale' ''

  # A C locale covers only the tests that follow it, in the scope it was
  # set in, and only as one unquoted word.
  put export-after-test scripts/a.sh '#!/usr/bin/env bash' '[[ $1 =~ [0-9] ]]' 'export LC_ALL=C'
  run_case export-after-test 1 '' "DIR/scripts/a.sh:2: regex range 0-9 follows the locale$(footer 1)"
  put export-in-subshell scripts/a.sh '#!/usr/bin/env bash' 'f() { ( export LC_ALL=C; true ); }' '[[ $1 =~ [0-9] ]]'
  run_case export-in-subshell 1 '' "DIR/scripts/a.sh:3: regex range 0-9 follows the locale$(footer 1)"
  put local-after-test scripts/a.sh '#!/usr/bin/env bash' 'f() { [[ $1 =~ [0-9] ]]; local LC_ALL=C; }'
  run_case local-after-test 1 '' "DIR/scripts/a.sh:2: regex range 0-9 follows the locale$(footer 1)"
  put local-suffixed-value scripts/a.sh '#!/usr/bin/env bash' 'f() { local LC_ALL=C${x}; [[ $1 =~ [0-9] ]]; }'
  run_case local-suffixed-value 1 '' "DIR/scripts/a.sh:2: regex range 0-9 follows the locale$(footer 1)"
  put local-scope-ends scripts/a.sh '#!/usr/bin/env bash' 'f() { local LC_ALL=C; :; }' '[[ $1 =~ [0-9] ]]'
  run_case local-scope-ends 1 '' "DIR/scripts/a.sh:3: regex range 0-9 follows the locale$(footer 1)"
  put local-twice scripts/a.sh '#!/usr/bin/env bash' 'f() { local LC_ALL=C; [[ $1 =~ [0-9] ]]; local LC_ALL=C.UTF-8; [[ $2 =~ [0-9] ]]; [[ $3 =~ [0-9] ]]; [[ $4 =~ [0-9] ]]; [[ $5 =~ [0-9] ]]; }'
  run_case local-twice 0 'regex-range-ascii: ok — scanned 1 file(s), 5 =~ test(s), 0 with a regex in a variable, 5 under a C locale' ''
  put for-loop-last-item scripts/a.sh '#!/usr/bin/env bash' 'for re in x "[0-9]+"; do' '  [[ $1 =~ $re ]]' 'done'
  run_case for-loop-last-item 1 '' "DIR/scripts/a.sh:3: regex range 0-9 (through re) follows the locale$(footer 1)"

  # A later write of another value ends a C locale; a write that does
  # not reach the test, or a prefix assignment, does not.
  put nested-local scripts/a.sh '#!/usr/bin/env bash' 'f() { g() { local LC_ALL=C; :; }; [[ $1 =~ [0-9] ]]; }'
  run_case nested-local 1 '' "DIR/scripts/a.sh:2: regex range 0-9 follows the locale$(footer 1)"
  put export-then-export scripts/a.sh '#!/usr/bin/env bash' 'export LC_ALL=C' 'export LC_ALL=en_US.UTF-8' '[[ $1 =~ [0-9] ]]'
  run_case export-then-export 1 '' "DIR/scripts/a.sh:4: regex range 0-9 follows the locale$(footer 1)"
  put export-then-unset scripts/a.sh '#!/usr/bin/env bash' 'export LC_ALL=C' 'unset LC_ALL' '' '[[ $1 =~ [0-9] ]]'
  run_case export-then-unset 1 '' "DIR/scripts/a.sh:5: regex range 0-9 follows the locale$(footer 1)"
  put export-then-assign scripts/a.sh '#!/usr/bin/env bash' 'export LC_ALL=C' 'LC_ALL=en_US.UTF-8' '' '' '[[ $1 =~ [0-9] ]]'
  run_case export-then-assign 1 '' "DIR/scripts/a.sh:6: regex range 0-9 follows the locale$(footer 1)"
  put export-then-local-other scripts/a.sh '#!/usr/bin/env bash' 'export LC_ALL=C' 'f() { local LC_ALL=en_US.UTF-8; [[ $1 =~ [0-9] ]]; }'
  run_case export-then-local-other 1 '' "DIR/scripts/a.sh:3: regex range 0-9 follows the locale$(footer 1)"
  put local-then-assign scripts/a.sh '#!/usr/bin/env bash' 'f() { local LC_ALL=C; LC_ALL=en_US.UTF-8; [[ $1 =~ [0-9] ]]; }' ''
  run_case local-then-assign 1 '' "DIR/scripts/a.sh:2: regex range 0-9 follows the locale$(footer 1)"
  put local-in-subshell scripts/a.sh '#!/usr/bin/env bash' 'f() { ( local LC_ALL=C; true ); [[ $1 =~ [0-9] ]]; }' '' ''
  run_case local-in-subshell 1 '' "DIR/scripts/a.sh:2: regex range 0-9 follows the locale$(footer 1)"
  put local-in-conditional scripts/a.sh '#!/usr/bin/env bash' 'f() { if (($#)); then local LC_ALL=C; fi; [[ $1 =~ [0-9] ]]; }' '' '' ''
  run_case local-in-conditional 1 '' "DIR/scripts/a.sh:2: regex range 0-9 follows the locale$(footer 1)"
  put other-locale-elsewhere scripts/a.sh '#!/usr/bin/env bash' 'export LC_ALL=C' 'f() { local LC_ALL=en_US.UTF-8; :; }' '[[ $1 =~ [0-9] ]]' '[[ $2 =~ [0-9] ]]' '[[ $3 =~ [0-9] ]]' '[[ $4 =~ [0-9] ]]' '[[ $5 =~ [0-9] ]]' '[[ $6 =~ [0-9] ]]'
  run_case other-locale-elsewhere 0 'regex-range-ascii: ok — scanned 1 file(s), 6 =~ test(s), 0 with a regex in a variable, 6 under a C locale' ''
  put prefix-assignment scripts/a.sh '#!/usr/bin/env bash' 'export LC_ALL=C' 'LC_ALL=en_US.UTF-8 cmd' '[[ $1 =~ [0-9] ]]' '[[ $2 =~ [0-9] ]]' '[[ $3 =~ [0-9] ]]' '[[ $4 =~ [0-9] ]]' '[[ $5 =~ [0-9] ]]' '[[ $6 =~ [0-9] ]]' '[[ $7 =~ [0-9] ]]'
  run_case prefix-assignment 0 'regex-range-ascii: ok — scanned 1 file(s), 7 =~ test(s), 0 with a regex in a variable, 7 under a C locale' ''
  put local-nested-other scripts/a.sh '#!/usr/bin/env bash' 'f() { local LC_ALL=C; g() { local LC_ALL=en_US.UTF-8; :; }; [[ $1 =~ [0-9] ]]; [[ $2 =~ [0-9] ]]; [[ $3 =~ [0-9] ]]; [[ $4 =~ [0-9] ]]; [[ $5 =~ [0-9] ]]; [[ $6 =~ [0-9] ]]; [[ $7 =~ [0-9] ]]; [[ $8 =~ [0-9] ]]; }'
  run_case local-nested-other 0 'regex-range-ascii: ok — scanned 1 file(s), 8 =~ test(s), 0 with a regex in a variable, 8 under a C locale' ''
  put export-twice-c scripts/a.sh '#!/usr/bin/env bash' 'export LC_ALL=C' 'export LC_ALL=C.UTF-8' '[[ $1 =~ [0-9] ]]' '[[ $2 =~ [0-9] ]]' '[[ $3 =~ [0-9] ]]' '[[ $4 =~ [0-9] ]]' '[[ $5 =~ [0-9] ]]' '[[ $6 =~ [0-9] ]]' '[[ $7 =~ [0-9] ]]' '[[ $8 =~ [0-9] ]]' '[[ $9 =~ [0-9] ]]'
  run_case export-twice-c 0 'regex-range-ascii: ok — scanned 1 file(s), 9 =~ test(s), 0 with a regex in a variable, 9 under a C locale' ''

  put write-before-export scripts/a.sh '#!/usr/bin/env bash' 'LC_ALL=en_US.UTF-8' 'export LC_ALL=C' '[[ $1 =~ [0-9] ]]' '[[ $2 =~ [0-9] ]]' '[[ $3 =~ [0-9] ]]' '[[ $4 =~ [0-9] ]]' '[[ $5 =~ [0-9] ]]' '[[ $6 =~ [0-9] ]]' '[[ $7 =~ [0-9] ]]' '[[ $8 =~ [0-9] ]]' '[[ $9 =~ [0-9] ]]' '[[ $10 =~ [0-9] ]]'
  run_case write-before-export 0 'regex-range-ascii: ok — scanned 1 file(s), 10 =~ test(s), 0 with a regex in a variable, 10 under a C locale' ''
  put write-after-test scripts/a.sh '#!/usr/bin/env bash' 'export LC_ALL=C' '[[ $1 =~ [0-9] ]]' '[[ $2 =~ [0-9] ]]' '[[ $3 =~ [0-9] ]]' '[[ $4 =~ [0-9] ]]' '[[ $5 =~ [0-9] ]]' '[[ $6 =~ [0-9] ]]' '[[ $7 =~ [0-9] ]]' '[[ $8 =~ [0-9] ]]' '[[ $9 =~ [0-9] ]]' '[[ $10 =~ [0-9] ]]' '[[ $11 =~ [0-9] ]]' 'export LC_ALL=en_US.UTF-8'
  run_case write-after-test 0 'regex-range-ascii: ok — scanned 1 file(s), 11 =~ test(s), 0 with a regex in a variable, 11 under a C locale' ''
  put c-write-elsewhere scripts/a.sh '#!/usr/bin/env bash' 'export LC_ALL=C' '( export LC_ALL=C )' 'LC_ALL=C' '[[ $1 =~ [0-9] ]]' '[[ $2 =~ [0-9] ]]' '[[ $3 =~ [0-9] ]]' '[[ $4 =~ [0-9] ]]' '[[ $5 =~ [0-9] ]]' '[[ $6 =~ [0-9] ]]' '[[ $7 =~ [0-9] ]]' '[[ $8 =~ [0-9] ]]' '[[ $9 =~ [0-9] ]]' '[[ $10 =~ [0-9] ]]' '[[ $11 =~ [0-9] ]]' '[[ $12 =~ [0-9] ]]'
  run_case c-write-elsewhere 0 'regex-range-ascii: ok — scanned 1 file(s), 12 =~ test(s), 0 with a regex in a variable, 12 under a C locale' ''

  # Only an unset of LC_ALL ends a C locale; a background export never
  # starts one; the last word of a declaration is the one that counts.
  put unset-other-variable scripts/a.sh '#!/usr/bin/env bash' 'export LC_ALL=C' 'foo=1' 'unset foo' '[[ $1 =~ [0-9] ]]' '[[ $2 =~ [0-9] ]]' '[[ $3 =~ [0-9] ]]' '[[ $4 =~ [0-9] ]]' '[[ $5 =~ [0-9] ]]' '[[ $6 =~ [0-9] ]]' '[[ $7 =~ [0-9] ]]' '[[ $8 =~ [0-9] ]]' '[[ $9 =~ [0-9] ]]' '[[ $10 =~ [0-9] ]]' '[[ $11 =~ [0-9] ]]' '[[ $12 =~ [0-9] ]]' '[[ $13 =~ [0-9] ]]'
  run_case unset-other-variable 0 'regex-range-ascii: ok — scanned 1 file(s), 13 =~ test(s), 0 with a regex in a variable, 13 under a C locale' ''
  put export-in-background scripts/a.sh '#!/usr/bin/env bash' 'export LC_ALL=C &' '[[ $1 =~ [0-9] ]]'
  run_case export-in-background 1 '' "DIR/scripts/a.sh:3: regex range 0-9 follows the locale$(footer 1)"
  put local-in-background scripts/a.sh '#!/usr/bin/env bash' 'f() {' '  local LC_ALL=C &' '  [[ $1 =~ [0-9] ]]' '}'
  run_case local-in-background 1 '' "DIR/scripts/a.sh:4: regex range 0-9 follows the locale$(footer 1)"
  put local-last-word-wins scripts/a.sh '#!/usr/bin/env bash' 'f() {' '  local LC_ALL=C LC_ALL=en_US.UTF-8' '  [[ $1 =~ [0-9] ]]' '}' ''
  run_case local-last-word-wins 1 '' "DIR/scripts/a.sh:4: regex range 0-9 follows the locale$(footer 1)"
  put local-last-word-c scripts/a.sh '#!/usr/bin/env bash' 'f() {' '  local LC_ALL=en_US.UTF-8 LC_ALL=C' '[[ $1 =~ [0-9] ]]' '[[ $2 =~ [0-9] ]]' '[[ $3 =~ [0-9] ]]' '[[ $4 =~ [0-9] ]]' '[[ $5 =~ [0-9] ]]' '[[ $6 =~ [0-9] ]]' '[[ $7 =~ [0-9] ]]' '[[ $8 =~ [0-9] ]]' '[[ $9 =~ [0-9] ]]' '[[ $10 =~ [0-9] ]]' '[[ $11 =~ [0-9] ]]' '[[ $12 =~ [0-9] ]]' '[[ $13 =~ [0-9] ]]' '[[ $14 =~ [0-9] ]]' '}'
  run_case local-last-word-c 0 'regex-range-ascii: ok — scanned 1 file(s), 14 =~ test(s), 0 with a regex in a variable, 14 under a C locale' ''
  put export-c-utf8 scripts/a.sh '#!/usr/bin/env bash' 'export LC_ALL=C.UTF-8' '[[ $1 =~ [0-9] ]]' '[[ $2 =~ [0-9] ]]' '[[ $3 =~ [0-9] ]]' '[[ $4 =~ [0-9] ]]' '[[ $5 =~ [0-9] ]]' '[[ $6 =~ [0-9] ]]' '[[ $7 =~ [0-9] ]]' '[[ $8 =~ [0-9] ]]' '[[ $9 =~ [0-9] ]]' '[[ $10 =~ [0-9] ]]' '[[ $11 =~ [0-9] ]]' '[[ $12 =~ [0-9] ]]' '[[ $13 =~ [0-9] ]]' '[[ $14 =~ [0-9] ]]' '[[ $15 =~ [0-9] ]]'
  run_case export-c-utf8 0 'regex-range-ascii: ok — scanned 1 file(s), 15 =~ test(s), 0 with a regex in a variable, 15 under a C locale' ''

  put export-before-test scripts/a.sh '#!/usr/bin/env bash' 'export LC_ALL=C' '[[ $1 =~ [0-9] ]]' '[[ $2 =~ [a-f] ]]' '[[ $3 =~ [A-Z] ]]' '[[ $4 =~ [a-z] ]]'
  run_case export-before-test 0 'regex-range-ascii: ok — scanned 1 file(s), 4 =~ test(s), 0 with a regex in a variable, 4 under a C locale' ''
  put local-before-test scripts/a.sh '#!/usr/bin/env bash' 'f() { local LC_ALL=C; [[ $1 =~ [0-9] ]]; }'
  run_case local-before-test 0 'regex-range-ascii: ok — scanned 1 file(s), 1 =~ test(s), 0 with a regex in a variable, 1 under a C locale' ''

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

  put no-jq scripts/a.sh '#!/usr/bin/env bash' '[[ $1 =~ [0-9] ]]'
  mkdir --parents "${work}/no-jq-bin"
  ln --symbolic -- "$(command -v shfmt)" "${work}/no-jq-bin/shfmt"
  ln --symbolic -- "$(command -v grep)" "${work}/no-jq-bin/grep"
  ln --symbolic -- "$(command -v bash)" "${work}/no-jq-bin/bash"
  CASE_ENV=("PATH=${work}/no-jq-bin")
  run_case no-jq 2 '' 'ERROR missing required tool: jq'
  CASE_ENV=()
}

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -ne 0 ]]; then
  printf '%d failure(s)\n' "${failures}" >&2
  exit 1
fi
