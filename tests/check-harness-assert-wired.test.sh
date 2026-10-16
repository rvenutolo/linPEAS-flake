#!/usr/bin/env bash
# tests/check-harness-assert-wired.test.sh
#
# Drives the harness-wiring lint against the fixture trees under
# tests/fixtures/harness-assert-wired, one scan root per detection branch.
#
# The lint holds every output-asserting harness
# to the cross-scenario discrimination gate, and the tree it scans by
# default is clean by construction. A clean scan exits 0 whatever the
# detection rules do, so on that path the rules run unexercised: breaking
# one costs nothing anybody would notice. Each row below points
# TESTS_DIR_OVERRIDE at a tree built to trip exactly one branch and holds
# the run to the exit code plus the diagnostic that branch alone prints,
# so a rule that stops firing takes a named scenario down with it.
#
# Rows cover the branches that print — the wiring verdict's three states,
# the discrimination-exemption ratchet, the parity ratchet on both sides
# of its reviewed allowlist, and the three count lines — and the branches
# whose whole effect is silence: a basename the lint holds out of
# scope, and a grep that extracts text rather than asserting a match. A
# silent branch is scored by the count the run reports and by a basename
# the output must never carry.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
# shellcheck source=scripts/lib/locale-gap.sh
source "${REPO_ROOT}/scripts/lib/locale-gap.sh"

readonly SCRIPT="${REPO_ROOT}/scripts/check-harness-assert-wired.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/harness-assert-wired"

cd "${REPO_ROOT}"

failures=0
asserted=0
work="$(mktemp --directory)"
trap 'rm --recursive --force -- "${work}"' EXIT

function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# One row per detection branch:
#   <scenario>|<scan root under the fixture tree>|<expected exit>|
#   <substring the output must NOT carry, empty for none>|
#   <substring the output must carry>[|<more>...]
# The first required substring is the one the discrimination gate records;
# the rest ride along on the same record, because they observe one run and
# recording that run once per substring would make the records identical
# siblings the gate cannot separate.
readonly -a ROWS=(
  # The whole fixture tree at once: three wiring states and the
  # discrimination ratchet, each naming its own harness.
  "mixed|.|1||comment-mention.test.sh asserts on captured output and is unwired|unwired.test.sh asserts on captured output and is unwired|half-wired.test.sh asserts on captured output and is half-wired (sources|exempting.test.sh registers a discrimination exemption|3 harness(es) grep captured output without the discrimination gate|1 harness(es) register a discrimination exemption; the escape hatch is held at zero"
  # A basename held out of scope: the tree would otherwise trip three
  # separate detections, and the run must report none of them.
  "exempt-skipped|exempt-skipped|0|refresh-just-recipes.test.sh|0 output-asserting harness(es) wired to the gate"
  # The parity ratchet's allowlisted side: counted, not reported, and the
  # wiring verdict still scores the harness as wired.
  "parity-allowlisted|parity-allowlisted|0||1 harness(es) register a parity exemption, each on the reviewed allowlist|1 output-asserting harness(es) wired to the gate"
  # The parity ratchet's other side: the same call from a harness nobody
  # reviewed for it.
  "parity-stray|parity-stray|1||stray-parity.test.sh registers a parity exemption and is not on the reviewed allowlist|1 harness(es) register a parity exemption off the reviewed allowlist"
  # Wiring's third state, which the fixture tree's own harnesses never
  # reach: the call without the library behind it.
  "verify-only|verify-only|1||verify-only.test.sh asserts on captured output and is half-wired (calls harness_assert_verify but never sources"
  # The verify token on a code line that does not open a statement.
  # Blanking comments cannot hide this one; only the anchor rejects it.
  "verify-mention|verify-mention|1||verify-mention.test.sh asserts on captured output and is half-wired (sources"
  # The assertion idiom's own filter: two quiet greps beside one
  # extracting grep, and only the two are held to the wiring verdict.
  "idiom-filter|idiom-filter|1|plain-grep.test.sh|2 harness(es) grep captured output without the discrimination gate|quiet-alpha.test.sh asserts on captured output and is unwired"
)

# A table that silently emptied would run no rows and report clean, which
# is the verdict these rows exist to make impossible. Score the table's own
# breadth before scoring anything it holds.
if ((${#ROWS[@]} == 0)); then
  printf 'check-harness-assert-wired: the row table is empty — no branch was exercised\n' >&2
  exit 2
fi

# @description Run the lint against one fixture scan root, score
# the outcome, and record it with the cross-scenario discrimination gate.
# Scores in the calling scope rather than returning through a command
# substitution: a substitution forks a subshell, and the gate's pool state
# lives in globals a subshell's exit would discard.
# @arg $1 scenario name  @arg $2 scan root  @arg $3 expected exit code
# @arg $4 substring the output must not carry ('' for none)
# @arg $@ substrings the output must carry
function run_row() {
  local -r name="$1" root="$2" want="$3" absent="$4"
  shift 4
  local -a subs=("$@")
  local -r out="${work}/${name}.out"
  local -r err="${work}/${name}.err"
  local -r outcome="${work}/${name}.outcome"

  local rc=0
  TESTS_DIR_OVERRIDE="${root}" bash "${SCRIPT}" >"${out}" 2>"${err}" || rc=$?
  # The exit code joins the recorded output so the gate compares verdicts
  # too: two roots whose diagnostics happen to coincide still differ here
  # when one of them is the clean path.
  printf 'check-harness-assert-wired: exit=%d\n' "${rc}" >"${outcome}"

  harness_assert_record "${name}" "${subs[0]}" "${outcome}" "${out}" "${err}"
  local i
  for ((i = 1; i < ${#subs[@]}; i++)); do
    harness_assert_also "${subs[i]}"
  done
  asserted=$((asserted + ${#subs[@]}))

  local ok='yes' sub
  if [[ ${rc} -ne ${want} ]]; then
    fail "${name}: expected exit ${want}, got ${rc}"
    ok='no'
  fi
  for sub in "${subs[@]}"; do
    if ! grep --fixed-strings --quiet -- "${sub}" "${out}" "${err}"; then
      fail "${name}: the run never printed ${sub@Q}"
      ok='no'
    fi
  done
  if [[ -n ${absent} ]] &&
    grep --fixed-strings --quiet -- "${absent}" "${out}" "${err}"; then
    fail "${name}: the run printed ${absent@Q}, which this branch must not reach"
    ok='no'
  fi
  if [[ ${ok} == 'yes' ]]; then
    pass "${name}: exit ${rc} with ${#subs[@]} diagnostic(s) only this branch prints"
  else
    cat -- "${out}" "${err}" >&2
  fi
}

row=''
for row in "${ROWS[@]}"; do
  fields=()
  IFS='|' read -r -a fields <<<"${row}"
  root="${FIXTURES}/${fields[1]}"
  # An absent root would make the lint scan nothing and exit 0,
  # which reads as "this branch does not fire" — a could-not-run wearing a
  # clean verdict, so it is refused before any row is scored.
  if [[ ! -d ${root} ]]; then
    printf 'check-harness-assert-wired: missing fixture scan root: %s\n' "${root}" >&2
    exit 2
  fi
  run_row "${fields[0]}" "${root}" "${fields[2]}" "${fields[3]}" "${fields[@]:4}"
done

# The assertion idiom's flag names are ASCII in every locale. Under
# en_US.UTF-8 a `[A-Za-z]` range in grep also admits `é`, so a harness
# whose only grep carries `--é` before its quiet flag would be held to
# the wiring verdict. It is not an assertion idiom, so only the two wired
# harnesses beside it are scored. The root is written at run time: its
# shape belongs to this one scenario, not to the fixture tree the rows
# share.
require_grep_locale_gap en_US.UTF-8 || exit 1
locale_root="${work}/non-ascii-flag"
mkdir -- "${locale_root}"
wired_text=$'#!/usr/bin/env bash\nsource scripts/lib/harness-assert.sh\ngrep --quiet PAYLOAD_RAN out.txt\nharness_assert_verify\n'
printf '%s' "${wired_text}" >"${locale_root}/wired-alpha.test.sh"
printf '%s' "${wired_text}" >"${locale_root}/wired-beta.test.sh"
printf '#!/usr/bin/env bash\ngrep --é --quiet PAYLOAD_RAN out.txt\n' \
  >"${locale_root}/accent-flag.test.sh"
LC_ALL=en_US.UTF-8 run_row 'non-ascii-flag-under-en-us' "${locale_root}" 0 \
  'accent-flag.test.sh' '2 output-asserting harness(es) wired to the gate'

printf '\ncheck-harness-assert-wired: %d detection branch(es) exercised, %d diagnostic substring(s) asserted\n' \
  "${#ROWS[@]}" "${asserted}"

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -gt 0 ]]; then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
