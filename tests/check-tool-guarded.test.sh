#!/usr/bin/env bash
# tests/check-tool-guarded.test.sh
#
# Verdict + failure-mode matrix for scripts/check-tool-guarded.sh.
#
# Every scenario drives the lint over a generated scan set via
# SCRIPTS_DIR_OVERRIDE. The fixtures are written at run time rather than
# committed, because a committed `.sh` whose whole purpose is to be a
# violation lands in the scan set of every other script lint in this tree
# and has to be excluded from each one by hand.
#
# The discriminating scenarios are the ones a textual matcher fails: a
# tool named only in a comment, in a message string, or inside a `sed`
# program text is not an invocation, and a guard written below the
# function that uses the tool still runs first.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-tool-guarded.sh"

failures=0
work="$(mktemp --directory)"
trap 'rm --recursive --force -- "${work}"' EXIT

function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# @description Run the lint over a scan set holding exactly one generated
# script, assert its exit code and an output substring, and record the
# outcome for the cross-scenario discrimination gate.
# @arg $1 scenario name
# @arg $2 expected exit code
# @arg $3 expected output substring (empty skips the substring assertion)
# @arg $4 the script body to write into the scan set
function run_scenario() {
  local -r name="$1" expected_exit="$2" substring="$3" body="$4"
  local -r dir="${work}/${name// /_}"
  mkdir -p -- "${dir}"
  printf '%s' "${body}" >"${dir}/subject.sh"
  local out outcome rc=0
  out="${work}/${name// /_}.out"
  outcome="${work}/${name// /_}.outcome"
  SCRIPTS_DIR_OVERRIDE="${dir}" bash "${SCRIPT}" >"${out}" 2>&1 || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${outcome}"
  if [[ ${rc} -ne ${expected_exit} ]]; then
    fail "${name} — expected exit ${expected_exit}, got ${rc}"
    cat -- "${out}" >&2
  elif [[ -n ${substring} ]] &&
    ! grep --fixed-strings --quiet -- "${substring}" "${out}"; then
    fail "${name} — output missing ${substring}"
    cat -- "${out}" >&2
  else
    pass "${name} (exit ${rc})"
  fi
  harness_assert_record "${name}" "${substring}" "${outcome}" "${out}"
}

function main() {
  # The defect this rule exists for: a tool invoked with no guard of any
  # kind. The diagnostic names the tool and the line it is invoked on.
  run_scenario 'an unguarded invocation is a violation' 1 \
    'invokes jq (line 4) but never guards it' \
    '#!/usr/bin/env bash
set -Eeuo pipefail

jq -e . payload.json
'

  # The three guard forms the rule accepts. Each is asserted separately
  # so a change that stops honoring one cannot pass on the strength of
  # another.
  run_scenario 'require_tool guards the invocation' 0 \
    'across 1 script(s) [jq=1]' \
    '#!/usr/bin/env bash
set -Eeuo pipefail
require_tool jq
jq -e . payload.json
'
  run_scenario 'a command -v test guards the invocation' 0 \
    'across 1 script(s) [yq=1]' \
    '#!/usr/bin/env bash
set -Eeuo pipefail
if ! command -v yq >/dev/null 2>&1; then
  exit 2
fi
yq eval . config.yml
'
  # require_json_payload calls require_tool jq itself, so a caller of it
  # is covered without repeating the guard.
  # shellcheck disable=SC2016 # fixture body: these are the subject's own
  # expansions and must reach the generated file unexpanded
  run_scenario 'require_json_payload guards jq for its caller' 0 \
    'across 1 script(s) [gh=1 jq=1]' \
    '#!/usr/bin/env bash
set -Eeuo pipefail
require_tool gh
require_json_payload SOURCE "${payload}"
gh api /rate_limit
jq -r .field <<<"${payload}"
'

  # The scenarios a textual matcher gets wrong. None of these is an
  # invocation, and a rule that flagged them would be excused rather than
  # fixed at every site.
  run_scenario 'a tool named only in prose is not an invocation' 0 \
    'scanned 1 script(s), 0 guarded invocation(s) across 0 script(s) []' \
    '#!/usr/bin/env bash
# This check reads its payload with jq, and yq elsewhere.
set -Eeuo pipefail
printf "install jq to run this\n" >&2
sed "s|jq||" </dev/null
'
  # A `||` inside a sed program is program text, not shell control flow,
  # and the tool word in that line is sed rather than what the program
  # happens to spell.
  run_scenario 'a pipe pair inside a sed program is not shell syntax' 0 \
    'across 1 script(s) [docker=1]' \
    '#!/usr/bin/env bash
set -Eeuo pipefail
require_tool docker
sed -E "s|^gh/||; s|jq||" </dev/null
docker version
'

  # Position is deliberately not part of the rule: a function defined
  # above the guard still runs after it.
  # shellcheck disable=SC2016 # fixture body: these are the subject's own
  # expansions and must reach the generated file unexpanded
  run_scenario 'a guard below the function that uses the tool is accepted' 0 \
    'across 1 script(s) [nix=1]' \
    '#!/usr/bin/env bash
set -Eeuo pipefail
function evaluate() {
  nix eval --json "$1"
}
function main() {
  require_tool nix
  evaluate "$1"
}
main "$@"
'

  # An empty scan set is a could-not-run, not a clean tree — the shared
  # enumeration convention every lint here follows.
  local out outcome rc=0
  mkdir -p -- "${work}/empty"
  out="${work}/empty.out"
  outcome="${work}/empty.outcome"
  SCRIPTS_DIR_OVERRIDE="${work}/empty" bash "${SCRIPT}" >"${out}" 2>&1 || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${outcome}"
  if [[ ${rc} -eq 2 ]] &&
    grep --fixed-strings --quiet -- 'matched 0 files' "${out}"; then
    pass "an empty scan set is a could-not-run (exit ${rc})"
  else
    fail "an empty scan set is a could-not-run — got exit ${rc}"
    cat -- "${out}" >&2
  fi
  harness_assert_record 'an empty scan set is a could-not-run' \
    'matched 0 files' "${outcome}" "${out}"

  # A file the parser cannot read is a could-not-run naming the file,
  # never a pass. Without this the lint would score an unparsable script
  # clean, which is the same silent-pass shape the rule exists to forbid.
  # shellcheck disable=SC2016 # fixture body: these are the subject's own
  # expansions and must reach the generated file unexpanded
  run_scenario 'an unparsable script is a could-not-run' 2 \
    'cannot parse' \
    '#!/usr/bin/env bash
if [[ -z "${x}" ; then
'

  # The live tree must satisfy its own rule.
  local live_rc=0
  local live_out="${work}/live.out"
  (cd "${REPO_ROOT}" && bash "${SCRIPT}") >"${live_out}" 2>&1 || live_rc=$?
  if [[ ${live_rc} -eq 0 ]]; then
    pass "live: every invocation in scripts/ is guarded (exit ${live_rc})"
  else
    fail "live: every invocation in scripts/ is guarded — exit ${live_rc}"
    cat -- "${live_out}" >&2
  fi

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
