#!/usr/bin/env bash
# tests/run-harness-group.test.sh
#
# Failure-mode harness for scripts/run-harness-group.sh. Seeds stub
# test harnesses + enforce scripts under temp dirs, drives the runner
# via TESTS_DIR_OVERRIDE + SCRIPTS_DIR_OVERRIDE, and asserts: exit
# codes, the summary table + $GITHUB_STEP_SUMMARY write, that one
# failing harness does not abort the rest, that the enforce-tagged
# harness DOES run its live script, that test-only harnesses do NOT
# run a same-named script, and that enforce is skipped when the test
# itself fails.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/run-harness-group.sh"

failures=0

# @arg $1 path  @arg $2 exit code  @arg $3 optional marker file to touch
function make_stub() {
  local -r path="$1" code="$2" marker="${3:-}"
  {
    printf '#!/usr/bin/env bash\n'
    [[ -n ${marker} ]] && printf 'touch %q\n' "${marker}"
    printf 'exit %s\n' "${code}"
  } >"${path}"
  chmod +x "${path}"
}

# Drives one scenario. Caller pre-builds $tests_dir and $scripts_dir.
# @arg $1 name  @arg $2 tests_dir  @arg $3 scripts_dir
# @arg $4 expected exit  @arg $5 expected stdout substring (empty skips)
# @arg $6 forbidden marker path for allowed-actions enforce (empty skips)
# @arg $7 forbidden marker path for settings-posture enforce (empty skips)
# @arg $8 forbidden marker path for ratchet enforce (empty skips)
# @arg $9 'skip-record' to keep this run out of the discrimination pool,
#      for a re-run of a seed another scenario already records (empty records)
function run_scenario() {
  local -r name="$1" tests_dir="$2" scripts_dir="$3"
  local -r expected_exit="$4" expected_out="$5"
  local -r forbidden_allowed="${6:-}" forbidden_settings="${7:-}" forbidden_ratchet="${8:-}"
  local -r skip_record="${9:-}"
  local outcome_file out_file step_file actual_exit=0
  outcome_file="$(mktemp)"
  out_file="$(mktemp)"
  step_file="$(mktemp)"
  TESTS_DIR_OVERRIDE="${tests_dir}" \
    SCRIPTS_DIR_OVERRIDE="${scripts_dir}" \
    ROOT_DIR_OVERRIDE="${tests_dir%/*}/root" \
    GITHUB_STEP_SUMMARY="${step_file}" \
    "${SCRIPT}" >"${out_file}" 2>&1 || actual_exit=$?
  # The exit code is part of what the run observably did, so it is recorded
  # alongside the streams rather than being checked only below.
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  if [[ ${skip_record} != 'skip-record' ]]; then
    harness_assert_record "${name}" "${expected_out}" \
      "${outcome_file}" "${out_file}" "${step_file}"
  fi

  # The tally line is the token a reader or a log grep matches on, so it has
  # to agree with the table it summarizes. Counting FAIL rows out of the
  # rendered table derives the expectation independently of however the
  # runner arrives at its own count, which is what catches a tally that
  # counts rows by matching a status cell the runner has since widened.
  local table_failed tally_line tally_failed
  table_failed="$(grep --count --extended-regexp '^\| [^|]+ \| FAIL' -- "${out_file}" || true)"
  tally_line="$(grep --extended-regexp \
    '^harness-group: [0-9]+/[0-9]+ harnesses passed, [0-9]+ failed$' \
    -- "${out_file}" || true)"
  tally_failed="${tally_line##*, }"
  tally_failed="${tally_failed% failed}"

  local failed_check=''
  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    failed_check="expected exit ${expected_exit}, got ${actual_exit}"
  elif [[ -n ${expected_out} ]] && ! grep --fixed-strings --quiet -- "${expected_out}" "${out_file}"; then
    failed_check="stdout missing '${expected_out}'"
  elif [[ -z ${tally_line} ]]; then
    failed_check='stdout missing the harness-group tally line'
  elif [[ ${tally_failed} != "${table_failed}" ]]; then
    failed_check="tally claims ${tally_failed} failed, table shows ${table_failed} FAIL row(s)"
  elif ! grep --fixed-strings --quiet -- '### harness-group' "${step_file}"; then
    failed_check='GITHUB_STEP_SUMMARY missing table header'
  elif [[ -n ${forbidden_allowed} && -e ${forbidden_allowed} ]]; then
    failed_check='allowed-actions-api harness wrongly ran its enforce script'
  elif [[ -n ${forbidden_settings} && -e ${forbidden_settings} ]]; then
    failed_check='settings-posture harness wrongly ran its enforce script'
  elif [[ -n ${forbidden_ratchet} && -e ${forbidden_ratchet} ]]; then
    failed_check='ratchet enforce ran despite test failure'
  fi

  if [[ -n ${failed_check} ]]; then
    printf 'FAIL: %s — %s\n' "${name}" "${failed_check}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi
  rm --force -- "${outcome_file}" "${out_file}" "${step_file}"
}

# The roster-mode scenarios below assert on captured output rather than on
# the summary table, so they report through these instead of run_scenario.
function pass_roster() { printf 'PASS: %s\n' "$1"; }
function fail_roster() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Seeds the five exact harness names in the runner's HARNESSES list. Exit
# codes per component are passed in; the allowed-actions and
# settings-posture enforce stubs (which the runner must never call for
# test-only harnesses) touch their respective forbidden markers when run.
# @arg $1 work dir  @arg $2 ratchet-test  $3 ratchet-enforce exit code
#      $4 allowed-test  $5 settings-test
#      $6 allowed forbidden-marker  $7 settings forbidden-marker
#      $8 ratchet-enforce forbidden-marker (optional)
#      $9 backfill-image-mode test exit code (optional, default 0)
#      $10 lib-log test exit code (optional, default 0)
#      $11 docs-audit-plant test exit code (optional, default 0)
function seed() {
  local -r work="$1"
  local -r tests_dir="${work}/tests" scripts_dir="${work}/scripts"
  local -r root_dir="${work}/root"
  local -r plant_rel='.claude/skills/docs-correctness-audit/evals/seeded-defects/plant.test.sh'
  mkdir -p "${tests_dir}" "${scripts_dir}" "${root_dir}"
  make_stub "${tests_dir}/check-ratchet-pin-audit.test.sh" "$2"
  make_stub "${scripts_dir}/check-ratchet-pin-audit.sh" "$3" "${8:-}"
  make_stub "${tests_dir}/check-allowed-actions-api.test.sh" "$4"
  make_stub "${tests_dir}/check-settings-posture.test.sh" "$5"
  # backfill-image-mode is a test-only harness (no enforce script).
  make_stub "${tests_dir}/classify-backfill-image-mode.test.sh" "${9:-0}"
  # lib-log is a test-only harness (no enforce script).
  make_stub "${tests_dir}/lib-log.test.sh" "${10:-0}"
  # Same-named enforce stubs the runner must NOT run for test-only harnesses.
  make_stub "${scripts_dir}/check-allowed-actions-api.sh" 0 "$6"
  make_stub "${scripts_dir}/check-settings-posture.sh" 0 "$7"

  # docs-audit-plant is the root-relative test-only harness the scenarios
  # below drive; seed it explicitly so its exit code is controllable.
  mkdir -p -- "${root_dir}/${plant_rel%/*}"
  make_stub "${root_dir}/${plant_rel}" "${11:-0}"

  # The runner declares harnesses beyond the scenario-controlled ones above.
  # Stub every other declared harness as passing so the fixture tree is
  # complete (the runner errors on a missing harness) and this spec-test
  # stays decoupled from the exact HARNESSES membership.
  # Both fields are stubbed, not just the test harness: an entry that
  # names an enforce script gets that script run too, so stubbing only
  # the harness leaves the runner calling a path the fixture tree does
  # not have. The `-e` guards keep the scenario-controlled stubs seeded
  # above — which carry specific exit codes and forbidden-call markers —
  # from being overwritten by a passing stub.
  local entry test_rel enforce_rel dest
  while IFS= read -r entry; do
    entry="${entry#*\'}"
    entry="${entry%%\'*}"
    IFS='|' read -r _ test_rel enforce_rel <<<"${entry}"
    [[ -n ${test_rel} ]] || continue
    if [[ ${test_rel} == */* ]]; then
      dest="${root_dir}/${test_rel}"
    else
      dest="${tests_dir}/${test_rel}"
    fi
    if [[ ! -e ${dest} ]]; then
      mkdir -p -- "${dest%/*}"
      make_stub "${dest}" 0
    fi
    [[ -n ${enforce_rel} ]] || continue
    dest="${scripts_dir}/${enforce_rel}"
    if [[ ! -e ${dest} ]]; then
      mkdir -p -- "${dest%/*}"
      make_stub "${dest}" 0
    fi
  done < <(grep -E "^[[:space:]]*'[^']+\|[^']+\.test\.sh\|[^']*'" "${SCRIPT}")
}

function main() {
  local work forbidden_allowed forbidden_settings

  # Scenario 1: all pass.
  work="$(mktemp -d)"
  forbidden_allowed="${work}/ran-allowed"
  forbidden_settings="${work}/ran-settings"
  seed "${work}" 0 0 0 0 "${forbidden_allowed}" "${forbidden_settings}"
  run_scenario 'all harnesses pass -> exit 0' \
    "${work}/tests" "${work}/scripts" 0 'harnesses passed, 0 failed' \
    "${forbidden_allowed}" "${forbidden_settings}"
  rm --recursive --force -- "${work}"

  # Scenario 2: one harness fails, others still run.
  work="$(mktemp -d)"
  forbidden_allowed="${work}/ran-allowed"
  forbidden_settings="${work}/ran-settings"
  seed "${work}" 0 0 0 1 "${forbidden_allowed}" "${forbidden_settings}"
  run_scenario 'settings-posture test fails -> exit 1' \
    "${work}/tests" "${work}/scripts" 1 '| settings-posture | FAIL (test) |' \
    "${forbidden_allowed}" "${forbidden_settings}"
  rm --recursive --force -- "${work}"

  work="$(mktemp -d)"
  forbidden_allowed="${work}/ran-allowed"
  forbidden_settings="${work}/ran-settings"
  seed "${work}" 0 0 0 1 "${forbidden_allowed}" "${forbidden_settings}"
  # Same seed as the scenario above, re-run to assert a second property of
  # that outcome: the harness after the failing one still ran. Its pass row
  # appears in every scenario that does not perturb allowed-actions-api, so
  # the row cannot discriminate between runs — the run stays out of the
  # discrimination pool rather than being exempted row by row.
  run_scenario 'failing harness does not abort the rest' \
    "${work}/tests" "${work}/scripts" 1 '| allowed-actions-api | pass |' \
    "${forbidden_allowed}" "${forbidden_settings}" '' 'skip-record'
  rm --recursive --force -- "${work}"

  # Scenario 3: ratchet test passes but its enforce script fails -> the row
  # names the enforce stage, proving the enforce script ran. Scenario 4 is
  # the same harness failing at the test stage; the stage-named cell is the
  # only thing that separates the two runs, so asserting it here is what
  # keeps "enforce ran" and "enforce was skipped" distinct observations.
  work="$(mktemp -d)"
  forbidden_allowed="${work}/ran-allowed"
  forbidden_settings="${work}/ran-settings"
  seed "${work}" 0 1 0 0 "${forbidden_allowed}" "${forbidden_settings}"
  run_scenario 'ratchet enforce script runs and can fail the row' \
    "${work}/tests" "${work}/scripts" 1 '| ratchet-pin-audit | FAIL (enforce) |' \
    "${forbidden_allowed}" "${forbidden_settings}"
  rm --recursive --force -- "${work}"

  # Scenario 4: ratchet TEST fails -> enforce must NOT run, and the row
  # names the test stage rather than the enforce stage it never reached.
  work="$(mktemp -d)"
  forbidden_allowed="${work}/ran-allowed"
  forbidden_settings="${work}/ran-settings"
  local forbidden_ratchet="${work}/ran-ratchet-enforce"
  seed "${work}" 1 0 0 0 "${forbidden_allowed}" "${forbidden_settings}" "${forbidden_ratchet}"
  run_scenario 'ratchet test fails -> enforce skipped, row FAIL' \
    "${work}/tests" "${work}/scripts" 1 '| ratchet-pin-audit | FAIL (test) |' \
    "${forbidden_allowed}" "${forbidden_settings}" "${forbidden_ratchet}"
  rm --recursive --force -- "${work}"

  # Scenario 5: the test-only backfill-image-mode harness fails -> row
  # FAIL, exit 1. Guards against the harness being dropped or its failure
  # being swallowed.
  work="$(mktemp -d)"
  forbidden_allowed="${work}/ran-allowed"
  forbidden_settings="${work}/ran-settings"
  seed "${work}" 0 0 0 0 "${forbidden_allowed}" "${forbidden_settings}" "" 1
  run_scenario 'backfill-image-mode test fails -> exit 1' \
    "${work}/tests" "${work}/scripts" 1 '| backfill-image-mode | FAIL (test) |' \
    "${forbidden_allowed}" "${forbidden_settings}"
  rm --recursive --force -- "${work}"

  # Scenario 6: the test-only lib-log harness fails -> row FAIL, exit 1.
  # Guards against the harness being dropped or its failure being
  # swallowed.
  work="$(mktemp -d)"
  forbidden_allowed="${work}/ran-allowed"
  forbidden_settings="${work}/ran-settings"
  seed "${work}" 0 0 0 0 "${forbidden_allowed}" "${forbidden_settings}" "" 0 1
  run_scenario 'lib-log test fails -> exit 1' \
    "${work}/tests" "${work}/scripts" 1 '| lib-log | FAIL (test) |' \
    "${forbidden_allowed}" "${forbidden_settings}"
  rm --recursive --force -- "${work}"

  # Scenario 7: a repo-root-relative harness fails -> row FAIL, exit 1. The
  # entry form that resolves outside tests/ has to fail as loudly as the rest,
  # or registering a harness there is registration without enforcement.
  work="$(mktemp -d)"
  forbidden_allowed="${work}/ran-allowed"
  forbidden_settings="${work}/ran-settings"
  seed "${work}" 0 0 0 0 "${forbidden_allowed}" "${forbidden_settings}" '' 0 0 1
  run_scenario 'root-relative harness fails -> exit 1' \
    "${work}/tests" "${work}/scripts" 1 '| docs-audit-plant | FAIL (test) |' \
    "${forbidden_allowed}" "${forbidden_settings}"
  rm --recursive --force -- "${work}"

  # Scenario 8: a root-relative entry whose file is absent names the path the
  # runner actually tried. A diagnostic naming only the filename would read
  # identically for a mistyped tests/ entry and a mistyped root-relative one.
  work="$(mktemp -d)"
  forbidden_allowed="${work}/ran-allowed"
  forbidden_settings="${work}/ran-settings"
  seed "${work}" 0 0 0 0 "${forbidden_allowed}" "${forbidden_settings}"
  rm --force -- "${work}/root/.claude/skills/docs-correctness-audit/evals/seeded-defects/plant.test.sh"
  run_scenario 'missing root-relative harness names its path' \
    "${work}/tests" "${work}/scripts" 1 \
    "missing test harness: ${work}/root/.claude/skills/docs-correctness-audit/evals/seeded-defects/plant.test.sh" \
    "${forbidden_allowed}" "${forbidden_settings}"
  rm --recursive --force -- "${work}"

  # Scenario 9: --print-roster prints the roster and runs nothing. The mode
  # exists so scripts/refresh-enforcement-matrix.sh can assert the
  # `ci: harness-group` annotation against the enforce field that decides
  # it, instead of scraping the array with a regex. The assertion is on the
  # shape every consumer parses — three pipe-delimited fields per line, the
  # third possibly empty — plus at least one entry actually carrying an
  # enforce script, since a roster where that field is empty everywhere
  # would satisfy a shape-only check while telling the consumer nothing.
  local roster_out roster_err roster_outcome roster_rc=0
  local roster_lines malformed enforce_lines table_rows
  roster_out="$(mktemp)"
  roster_err="$(mktemp)"
  roster_outcome="$(mktemp)"
  "${SCRIPT}" --print-roster >"${roster_out}" 2>"${roster_err}" || roster_rc=$?
  roster_lines="$(wc -l <"${roster_out}" | tr -d '[:space:]')"
  malformed="$(grep --count --invert-match --extended-regexp \
    '^[^|[:space:]]+\|[^|[:space:]]+\|[^|[:space:]]*$' -- "${roster_out}" || true)"
  enforce_lines="$(grep --count --extended-regexp '\|[^|[:space:]]+$' -- "${roster_out}" || true)"
  # "runs nothing" is the other half of the claim, and it is checked
  # rather than assumed: a run emits the summary table, so the table's
  # absence is what separates printing the roster from printing it after
  # executing every harness in the tree.
  table_rows="$(grep --count --fixed-strings \
    -- '| harness | result | time |' "${roster_out}" || true)"
  printf 'harness-assert-outcome: exit=%d entries=%s malformed=%s with-enforce=%s table-rows=%s\n' \
    "${roster_rc}" "${roster_lines}" "${malformed}" "${enforce_lines}" \
    "${table_rows}" >"${roster_outcome}"
  harness_assert_record '--print-roster prints the roster and runs nothing' \
    '' "${roster_outcome}" "${roster_out}" "${roster_err}"
  if [[ ${roster_rc} -eq 0 ]] && [[ ${roster_lines} -gt 0 ]] &&
    [[ ${malformed} -eq 0 ]] && [[ ${enforce_lines} -gt 0 ]] &&
    [[ ${table_rows} -eq 0 ]]; then
    pass_roster "--print-roster printed ${roster_lines} well-formed entries, ${enforce_lines} with an enforce script, no summary table"
  else
    fail_roster "--print-roster: exit ${roster_rc}, ${roster_lines} entries, ${malformed} malformed, ${enforce_lines} with an enforce script, ${table_rows} table header(s)"
    cat -- "${roster_err}" >&2
  fi
  rm --force -- "${roster_out}" "${roster_err}" "${roster_outcome}"

  # Scenario 10: an unrecognized argument is a usage error, not a run. A
  # mode reached by name is only load-bearing if a caller that misspells it
  # fails loudly rather than silently running every harness.
  local bad_out bad_err bad_outcome bad_rc=0
  bad_out="$(mktemp)"
  bad_err="$(mktemp)"
  bad_outcome="$(mktemp)"
  "${SCRIPT}" --print-rooster >"${bad_out}" 2>"${bad_err}" || bad_rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${bad_rc}" >"${bad_outcome}"
  harness_assert_record 'unknown argument is a usage error' \
    'unknown argument: --print-rooster' "${bad_outcome}" "${bad_out}" "${bad_err}"
  if [[ ${bad_rc} -eq 2 ]] &&
    grep --fixed-strings --quiet -- 'unknown argument: --print-rooster' "${bad_err}" &&
    [[ ! -s ${bad_out} ]]; then
    pass_roster 'unknown argument exits 2 without running a harness'
  else
    fail_roster "unknown argument: want exit 2 and no stdout, got exit ${bad_rc}"
    cat -- "${bad_err}" >&2
  fi
  rm --force -- "${bad_out}" "${bad_err}" "${bad_outcome}"

  # Scenario 11: a trailing argument after the mode is a usage error too.
  # Without this the extra-argument guard could be dropped and the mode
  # would still answer, quietly accepting a call whose author meant
  # something the script does not do.
  local extra_out extra_err extra_outcome extra_rc=0
  extra_out="$(mktemp)"
  extra_err="$(mktemp)"
  extra_outcome="$(mktemp)"
  "${SCRIPT}" --print-roster stray >"${extra_out}" 2>"${extra_err}" || extra_rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${extra_rc}" >"${extra_outcome}"
  harness_assert_record 'extra argument after the mode is a usage error' \
    'unexpected extra arguments after --print-roster' \
    "${extra_outcome}" "${extra_out}" "${extra_err}"
  if [[ ${extra_rc} -eq 2 ]] && [[ ! -s ${extra_out} ]]; then
    pass_roster 'extra argument after --print-roster exits 2 without printing'
  else
    fail_roster "extra argument: want exit 2 and no stdout, got exit ${extra_rc}"
    cat -- "${extra_err}" >&2
  fi
  rm --force -- "${extra_out}" "${extra_err}" "${extra_outcome}"

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d scenario(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
