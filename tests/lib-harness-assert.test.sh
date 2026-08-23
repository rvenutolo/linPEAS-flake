#!/usr/bin/env bash
# @subject scripts/lib/harness-assert.sh
# tests/lib-harness-assert.test.sh — proves the cross-scenario
# discrimination gate flags a substring that also appears in a sibling
# scenario's output, and stays quiet when the substring discriminates.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly LIB="${REPO_ROOT}/scripts/lib/harness-assert.sh"

failures=0
work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT

# @description Run a library-driving snippet in a fresh bash process.
# @arg $1 case name  @arg $2 expected exit  @arg $3 expected stdout
#      substring ('' to skip)  @arg $4 snippet body
function check() {
  local -r name="$1" want_rc="$2" want_sub="$3" body="$4"
  local script out rc=0
  script="${work}/case.sh"
  out="${work}/case.out"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -Eeuo pipefail\n'
    printf "IFS=\$'\\\\n\\\\t'\n"
    printf 'source %q\n' "${LIB}"
    printf '%s\n' "${body}"
  } >"${script}"
  bash "${script}" >"${out}" 2>&1 || rc=$?

  if [[ ${rc} -ne ${want_rc} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' "${name}" "${want_rc}" "${rc}" >&2
    cat -- "${out}" >&2
    failures=$((failures + 1))
  elif [[ -n ${want_sub} ]] &&
    ! grep --fixed-strings --quiet -- "${want_sub}" "${out}"; then
    printf 'FAIL: %s — output missing %q\n' "${name}" "${want_sub}" >&2
    cat -- "${out}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s\n' "${name}"
  fi
}

# Helper snippet fragment: write two scenario output files.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
readonly SETUP='
d="$(mktemp -d)"
printf "gathering last bump PR\nwrote dashboard\n" >"${d}/nominal.out"
printf "WARN degraded lookup: bump PR\n"           >"${d}/degraded.out"
'

# shellcheck disable=SC2016 # every snippet below is bash source text for a child process, not text to expand here
function main() {
  # The class regression: the degraded scenario asserts a token that the
  # nominal scenario also prints. This is the shape that passed against
  # an unfixed script.
  check 'non-discriminating substring is flagged' 1 'does not discriminate' "${SETUP}"'
harness_assert_record nominal  "wrote dashboard" "${d}/nominal.out"
harness_assert_record degraded "bump PR"         "${d}/degraded.out"
harness_assert_verify'

  check 'flag names both scenarios' 1 'degraded' "${SETUP}"'
harness_assert_record nominal  "wrote dashboard" "${d}/nominal.out"
harness_assert_record degraded "bump PR"         "${d}/degraded.out"
harness_assert_verify'

  # Narrowed to a token unique to the failure path.
  check 'discriminating substring passes' 0 'checked 2 substring assertions across 2 scenarios' "${SETUP}"'
harness_assert_record nominal  "wrote dashboard"        "${d}/nominal.out"
harness_assert_record degraded "WARN degraded lookup"   "${d}/degraded.out"
harness_assert_verify'

  # Two bad-* fixtures sharing one diagnostic: the substring each asserts
  # is the substring the other declares, so the pairwise rule has nothing
  # to say about it. The pool collapses to one outcome, which is what the
  # parity exemption here is for, so the case reads the pairwise rule
  # alone.
  check 'identical substrings do not flag each other' 0 'checked 2' '
harness_assert_parity_exempt a b "pool constructed to exercise the pairwise rule"
d="$(mktemp -d)"
printf "marker missing\n" >"${d}/a.out"
printf "marker missing\n" >"${d}/b.out"
harness_assert_record a "marker missing" "${d}/a.out"
harness_assert_record b "marker missing" "${d}/b.out"
harness_assert_verify'

  # A scenario asserting nothing still contributes its output.
  check 'assertion-free scenario still pollutes the pool' 1 'does not discriminate' "${SETUP}"'
harness_assert_record nominal  "" "${d}/nominal.out"
harness_assert_record degraded "bump PR" "${d}/degraded.out"
harness_assert_verify'

  check 'assertion-free scenario is not counted as an assertion' 1 'checked 1 substring assertions across 2 scenarios' "${SETUP}"'
harness_assert_record nominal  "" "${d}/nominal.out"
harness_assert_record degraded "bump PR" "${d}/degraded.out"
harness_assert_verify'

  # Exemption suppresses exactly one pair.
  check 'exemption suppresses the named pair' 0 'checked 2' "${SETUP}"'
harness_assert_exempt "bump PR" nominal "script prints the label on every run"
harness_assert_record nominal  "wrote dashboard" "${d}/nominal.out"
harness_assert_record degraded "bump PR"         "${d}/degraded.out"
harness_assert_verify'

  check 'exemption for a different scenario does not suppress' 1 'does not discriminate' "${SETUP}"'
harness_assert_exempt "bump PR" someone-else "unrelated"
harness_assert_record nominal  "wrote dashboard" "${d}/nominal.out"
harness_assert_record degraded "bump PR"         "${d}/degraded.out"
harness_assert_verify'

  check 'exemption without a rationale is rejected' 1 'rationale' '
harness_assert_exempt "x" y ""'

  # A `*` exemption covers a banner every scenario of an outcome class
  # prints; the substring still separates that class from its opposite.
  check 'wildcard exemption suppresses every pair' 0 'checked 2' "${SETUP}"'
harness_assert_exempt "bump PR" "*" "progress label printed on every run"
harness_assert_record nominal  "wrote dashboard" "${d}/nominal.out"
harness_assert_record degraded "bump PR"         "${d}/degraded.out"
harness_assert_verify'

  check 'wildcard exemption is scoped to its own substring' 1 'wrote dashboard' '
d="$(mktemp -d)"
printf "wrote dashboard\nbump PR\n" >"${d}/a.out"
printf "wrote dashboard\n"          >"${d}/b.out"
harness_assert_exempt "bump PR" "*" "progress label printed on every run"
harness_assert_record a "bump PR"         "${d}/a.out"
harness_assert_record b "wrote dashboard" "${d}/b.out"
harness_assert_verify'

  # Two scenarios emitting one diagnostic differ only by the logger'"'"'s
  # timestamp. Comparing raw bytes would make the verdict depend on whether
  # the two runs landed in the same second, so the census would flap.
  check 'log timestamps do not make two identical outputs differ' 0 'across 2 scenarios (1 distinct outputs)' '
harness_assert_parity_exempt a b "pool constructed to exercise timestamp normalization"
d="$(mktemp -d)"
printf "[2026-01-02T03:04:05-0500] ERROR BEGIN marker missing from doc.md\n" >"${d}/a.out"
printf "[2026-01-02T03:04:06-0500] ERROR BEGIN marker missing from doc.md\n" >"${d}/b.out"
harness_assert_record a "BEGIN marker missing" "${d}/a.out"
harness_assert_record b "BEGIN marker missing" "${d}/b.out"
harness_assert_verify'

  check 'a difference beyond the timestamp still flags' 1 'does not discriminate' '
d="$(mktemp -d)"
printf "[2026-01-02T03:04:05-0500] ERROR BEGIN marker missing from doc.md\n" >"${d}/a.out"
printf "[2026-01-02T03:04:06-0500] ERROR BEGIN marker missing from other.md\n" >"${d}/b.out"
harness_assert_record a "BEGIN marker missing" "${d}/a.out"
harness_assert_record b "marker missing from other.md" "${d}/b.out"
harness_assert_verify'

  check 'census reports the distinct-output count' 0 'across 3 scenarios (2 distinct outputs)' '
harness_assert_parity_exempt a b "pool constructed to exercise the distinct-output count"
d="$(mktemp -d)"
printf "alpha\nbeta\n" >"${d}/a.out"
printf "alpha\nbeta\n" >"${d}/b.out"
printf "gamma\n"       >"${d}/c.out"
harness_assert_record a "alpha" "${d}/a.out"
harness_assert_record b "alpha" "${d}/b.out"
harness_assert_record c "gamma" "${d}/c.out"
harness_assert_verify'

  # Dedupe must not hide a genuine collision with a third, differing output.
  check 'identical-output dedupe still flags a differing sibling' 1 'does not discriminate' '
d="$(mktemp -d)"
printf "alpha\n"        >"${d}/a.out"
printf "alpha\n"        >"${d}/b.out"
printf "alpha carried\n" >"${d}/c.out"
harness_assert_record a "alpha"   "${d}/a.out"
harness_assert_record b ""        "${d}/b.out"
harness_assert_record c "carried" "${d}/c.out"
harness_assert_verify'

  # Multiple recorded streams per scenario.
  check 'second recorded stream is also compared' 1 'does not discriminate' '
d="$(mktemp -d)"
printf "quiet\n"          >"${d}/a.out"
printf "gathering parity\n" >"${d}/a.err"
printf "parity\n"          >"${d}/b.err"
harness_assert_record a ""       "${d}/a.out" "${d}/a.err"
harness_assert_record b "parity" "${d}/b.err"
harness_assert_verify'

  # One invocation asserting several properties is one record. Recording
  # it once per property would make those records byte-identical
  # siblings, which no substring can separate.
  check 'attached substring is checked against siblings' 1 'does not discriminate' "${SETUP}"'
harness_assert_record nominal  "wrote dashboard" "${d}/nominal.out"
harness_assert_also   "bump PR"
harness_assert_record degraded "WARN degraded lookup" "${d}/degraded.out"
harness_assert_verify'

  check 'attached substring counts as an assertion' 0 'checked 3 substring assertions across 2 scenarios' '
d="$(mktemp -d)"
printf "alpha\nbeta\n" >"${d}/a.out"
printf "gamma\n"       >"${d}/b.out"
harness_assert_record a "alpha" "${d}/a.out"
harness_assert_also   "beta"
harness_assert_record b "gamma" "${d}/b.out"
harness_assert_verify'

  check 'also before any record fails closed' 1 'called before any record' '
harness_assert_also "orphan"'

  # Identical output with differing assertions: neither substring can
  # separate the two, and the pairwise rule skips the pair by design. The
  # parity exemption is what a harness registers for such a pair, and the
  # rule below is the guarantee that still holds once parity has excused
  # it — so these two cases prove the rules compose.
  check 'identical output with differing assertions is flagged' 1 'assert different substrings' '
harness_assert_parity_exempt a b "pool constructed to exercise the identical-output rule"
d="$(mktemp -d)"
printf "alpha beta\n" >"${d}/a.out"
printf "alpha beta\n" >"${d}/b.out"
harness_assert_record a "alpha" "${d}/a.out"
harness_assert_record b "beta"  "${d}/b.out"
harness_assert_verify'

  check 'identical output where one asserts nothing is flagged' 1 'assert different substrings' '
harness_assert_parity_exempt a b "pool constructed to exercise the identical-output rule"
d="$(mktemp -d)"
printf "alpha beta\n" >"${d}/a.out"
printf "alpha beta\n" >"${d}/b.out"
harness_assert_record a "alpha" "${d}/a.out"
harness_assert_record b ""      "${d}/b.out"
harness_assert_verify'

  check 'identical output with identical assertions still passes' 0 'checked 2' '
harness_assert_parity_exempt a b "pool constructed to exercise the identical-output rule"
d="$(mktemp -d)"
printf "marker missing\n" >"${d}/a.out"
printf "marker missing\n" >"${d}/b.out"
harness_assert_record a "marker missing" "${d}/a.out"
harness_assert_record b "marker missing" "${d}/b.out"
harness_assert_verify'

  check 'census names the scenarios sharing an output' 0 "sharing one output: 'a', 'b'" '
harness_assert_parity_exempt a b "pool constructed to exercise the census naming"
d="$(mktemp -d)"
printf "same\n" >"${d}/a.out"
printf "same\n" >"${d}/b.out"
harness_assert_record a "" "${d}/a.out"
harness_assert_record b "" "${d}/b.out"
harness_assert_verify'

  # Parity: two scenarios whose whole observable outcome is the same
  # verify one thing between them, so matching assertions do not rescue
  # the pair — the second scenario adds no evidence the first lacks.
  check 'two scenarios sharing one outcome are flagged' 1 'share one observable outcome' '
d="$(mktemp -d)"
printf "marker missing\n" >"${d}/a.out"
printf "marker missing\n" >"${d}/b.out"
harness_assert_record a "marker missing" "${d}/a.out"
harness_assert_record b "marker missing" "${d}/b.out"
harness_assert_verify'

  check 'the parity diagnostic offers merging as a way out' 1 'harness_assert_also' '
d="$(mktemp -d)"
printf "marker missing\n" >"${d}/a.out"
printf "marker missing\n" >"${d}/b.out"
harness_assert_record a "marker missing" "${d}/a.out"
harness_assert_record b "marker missing" "${d}/b.out"
harness_assert_verify'

  check 'parity exemption suppresses the named pair' 0 'checked 2' '
harness_assert_parity_exempt a b "the fixtures differ in an input the script never reads"
d="$(mktemp -d)"
printf "marker missing\n" >"${d}/a.out"
printf "marker missing\n" >"${d}/b.out"
harness_assert_record a "marker missing" "${d}/a.out"
harness_assert_record b "marker missing" "${d}/b.out"
harness_assert_verify'

  check 'parity exemption for a different pair does not suppress' 1 'share one observable outcome' '
harness_assert_parity_exempt a c "unrelated pair"
d="$(mktemp -d)"
printf "marker missing\n" >"${d}/a.out"
printf "marker missing\n" >"${d}/b.out"
harness_assert_record a "marker missing" "${d}/a.out"
harness_assert_record b "marker missing" "${d}/b.out"
harness_assert_verify'

  check 'parity exemption without a rationale is rejected' 1 'rationale' '
harness_assert_parity_exempt a b ""'

  # Fail-closed cases.
  check 'verify with no records fails closed' 1 'no scenarios recorded' '
harness_assert_verify'

  check 'single-scenario harness reports a zero census' 0 'checked 0 substring assertions across 1 scenarios' '
d="$(mktemp -d)"
printf "only\n" >"${d}/a.out"
harness_assert_record a "" "${d}/a.out"
harness_assert_verify'

  check 'missing output file fails loud' 1 'output file not found' '
harness_assert_record a "x" /nonexistent/path.out'

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
