#!/usr/bin/env bash
# tests/run-lint-group.test.sh
#
# Failure-mode harness for scripts/run-lint-group.sh. Builds a throwaway
# manifest + stub check scripts in a temp dir, drives the runner via the
# *_OVERRIDE env vars, and asserts exit codes, the summary table, and
# that one failing check does NOT abort the rest of the group.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/run-lint-group.sh"

failures=0

# @arg $1 scenario name
# @arg $2 group arg to pass
# @arg $3 expected exit
# @arg $4 expected stdout substring (empty skips)
# @arg $5 the whole expected output (optional)
function run_scenario() {
  local -r name="$1" group="$2" expected_exit="$3" expected_out="$4" expected_whole="${5-}"
  local outcome_file out_file step_file work scripts_dir tests_dir manifest
  work="$(mktemp -d)"
  scripts_dir="${work}/scripts"
  tests_dir="${work}/tests"
  manifest="${work}/lint-groups.yml"
  mkdir -p "${scripts_dir}" "${tests_dir}"

  # Every group owns at least one check no other group lists, so a
  # row-plus-status assertion can only match the group it belongs to.
  printf '#!/usr/bin/env bash\nexit 0\n' >"${scripts_dir}/check-aaa.sh"
  printf '#!/usr/bin/env bash\nexit 1\n' >"${scripts_dir}/check-bbb.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${scripts_dir}/check-ccc.sh"
  printf '#!/usr/bin/env bash\nexit 1\n' >"${scripts_dir}/check-fff.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${scripts_dir}/check-zzz.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${scripts_dir}/check-qqq.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${scripts_dir}/check-mmm.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${scripts_dir}/check-ddd.sh"
  # demo-reverse lists its slowest check first, so a table in manifest
  # order proves the rows follow the manifest and not the finish order,
  # and fast's body landing after the last done line proves the output
  # is replayed once every check has finished.
  printf '#!/usr/bin/env bash\nsleep 0.6\nexit 0\n' >"${scripts_dir}/check-slow.sh"
  printf '#!/usr/bin/env bash\nsleep 0.3\nexit 0\n' >"${scripts_dir}/check-mid.sh"
  printf '#!/usr/bin/env bash\nprintf "fast-body\\n"\nexit 0\n' >"${scripts_dir}/check-fast.sh"
  chmod +x "${scripts_dir}"/check-*.sh
  # demo-first-fail puts its failing check first, so a zzz row proves the
  # runner kept going instead of aborting on the first failure.
  cat >"${manifest}" <<YAML
demo-all-pass:
  - aaa
  - ccc
demo-one-fail:
  - aaa
  - bbb
demo-first-fail:
  - fff
  - zzz
demo-missing:
  - aaa
  - nope
'q"x':
  - qqq
twice:
  - aaa
twice:
  - ddd
demo-reverse:
  - slow
  - mid
  - fast
YAML
  # A merge key makes yq warn on stderr whatever is read, so it goes
  # only into the manifest of the scenario that sets MANIFEST_EXTRA.
  if [[ -n ${MANIFEST_EXTRA:-} ]]; then
    printf '%s' "${MANIFEST_EXTRA}" >>"${manifest}"
  fi
  # MANIFEST_BODY replaces the manifest whole.
  if [[ -n ${MANIFEST_BODY:-} ]]; then
    printf '%s' "${MANIFEST_BODY}" >"${manifest}"
  fi

  outcome_file="$(mktemp)"
  out_file="$(mktemp)"
  step_file="$(mktemp)"
  local actual_exit=0
  LINT_GROUPS_OVERRIDE="${manifest}" \
    SCRIPTS_DIR_OVERRIDE="${scripts_dir}" \
    TESTS_DIR_OVERRIDE="${tests_dir}" \
    GITHUB_STEP_SUMMARY="${step_file}" \
    "${SCRIPT}" "${group}" >"${out_file}" 2>&1 || actual_exit=$?
  # The exit code is part of what the run observably did, so it is recorded
  # alongside the streams rather than being checked only below.
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_out}" \
    "${outcome_file}" "${out_file}" "${step_file}"

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_whole} && $(<"${out_file}") != "${expected_whole}" ]]; then
    printf 'FAIL: %s — output is not %q\n' "${name}" "${expected_whole}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_out} ]] && ! grep --fixed-strings --quiet -- "${expected_out}" "${out_file}"; then
    printf 'FAIL: %s — stdout missing %q\n' "${name}" "${expected_out}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ ${expected_exit} -lt 2 ]] && ! grep --fixed-strings --quiet -- '### ' "${step_file}"; then
    # Config errors (exit 2) bail before the table; only assert the
    # $GITHUB_STEP_SUMMARY write when checks actually ran.
    printf 'FAIL: %s — GITHUB_STEP_SUMMARY missing table header\n' "${name}" >&2
    failures=$((failures + 1))
  elif [[ ${expected_exit} -lt 2 ]] && ! rows_have_done_lines "${out_file}"; then
    printf 'FAIL: %s — a table row lacks its done line\n' "${name}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ ${group} == demo-reverse ]] && ! rows_in_order "${out_file}" slow mid fast; then
    printf 'FAIL: %s — table rows do not follow the manifest order\n' "${name}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ ${group} == demo-reverse ]] && ! body_after_done_lines "${out_file}" 'fast-body'; then
    printf 'FAIL: %s — check output was not replayed after the last done line\n' "${name}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi
  rm --recursive --force -- "${work}" "${outcome_file}" "${out_file}" "${step_file}"
}

# @description Assert every table row of a runner's output has a `done:`
# line naming the same check.
# @arg $1 captured runner output
function rows_have_done_lines() {
  local -a rows=()
  local row
  mapfile -t rows < <(sed --quiet --regexp-extended 's/^\| ([^ |]+) \| (pass|FAIL) .*$/\1/p' -- "$1")
  [[ ${#rows[@]} -gt 0 ]] || return 1
  for row in "${rows[@]}"; do
    grep --quiet --fixed-strings -- "done: ${row} " "$1" || return 1
  done
}

# @description Assert the table rows name the checks in the given order.
# @arg $1 captured runner output  @arg $@ check names in expected order
function rows_in_order() {
  local -r out="$1"
  shift
  local got
  got="$(sed --quiet --regexp-extended 's/^\| ([^ |]+) \| (pass|FAIL) .*$/\1/p' -- "${out}" | tr '\n' ' ')"
  # Joined by printf rather than `$*`: the harness's IFS starts with a
  # newline, which is what `$*` would join on.
  [[ ${got} == "$(printf '%s ' "$@")" ]]
}

# @description Assert a line of check output appears only after the last
# `done:` line, which is where a replayed buffer lands.
# @arg $1 captured runner output  @arg $2 the check output line
function body_after_done_lines() {
  local last_done first_body
  last_done="$(grep --line-number --fixed-strings -- 'done: ' "$1" | tail --lines=1 | cut --delimiter=: --fields=1)"
  first_body="$(grep --line-number --fixed-strings -- "$2" "$1" | head --lines=1 | cut --delimiter=: --fields=1)"
  [[ -n ${last_done} && -n ${first_body} && ${first_body} -gt ${last_done} ]]
}

# @description Prove a failing check *.test.sh skips its check script and
#              marks the row FAIL (the runner gates each check on its test).
function run_test_gate_scenario() {
  local work scripts_dir tests_dir manifest outcome_file out_file step_file sentinel
  work="$(mktemp -d)"
  scripts_dir="${work}/scripts"
  tests_dir="${work}/tests"
  manifest="${work}/lint-groups.yml"
  sentinel="${work}/ran"
  mkdir -p "${scripts_dir}" "${tests_dir}"
  # The check would pass AND leave a sentinel if it ran...
  printf '#!/usr/bin/env bash\ntouch %q\nexit 0\n' "${sentinel}" >"${scripts_dir}/check-ttt.sh"
  # ...but its test fails, so the runner must skip the check script.
  printf '#!/usr/bin/env bash\nexit 1\n' >"${tests_dir}/check-ttt.test.sh"
  chmod +x "${scripts_dir}"/check-*.sh "${tests_dir}"/check-*.test.sh
  printf 'demo-testfail:\n  - ttt\n' >"${manifest}"

  outcome_file="$(mktemp)"
  out_file="$(mktemp)"
  step_file="$(mktemp)"
  local actual_exit=0
  LINT_GROUPS_OVERRIDE="${manifest}" \
    SCRIPTS_DIR_OVERRIDE="${scripts_dir}" \
    TESTS_DIR_OVERRIDE="${tests_dir}" \
    GITHUB_STEP_SUMMARY="${step_file}" \
    "${SCRIPT}" demo-testfail >"${out_file}" 2>&1 || actual_exit=$?
  # The exit code is part of what the run observably did, so it is recorded
  # alongside the streams rather than being checked only below.
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record 'failing check test skips the check script' \
    '| ttt | FAIL |' "${outcome_file}" "${out_file}" "${step_file}"

  if [[ ${actual_exit} -ne 1 ]]; then
    printf 'FAIL: failing test -> expected exit 1, got %d\n' "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- '| ttt | FAIL |' "${out_file}"; then
    printf 'FAIL: failing test -> ttt not marked FAIL\n' >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ -e ${sentinel} ]]; then
    printf 'FAIL: failing test did not skip the check script (sentinel present)\n' >&2
    failures=$((failures + 1))
  else
    printf 'PASS: failing check test skips the check script and marks it FAIL\n'
  fi
  rm --recursive --force -- "${work}" "${outcome_file}" "${out_file}" "${step_file}"
}

# @description Run against a manifest that does not parse. yq exits 1 on
# it, and an unchecked read would leave the runner carrying that 1 — the
# same status a lint in the group reports when it finds a violation.
function run_unparsable_manifest_scenario() {
  local manifest outcome_file out_file step_file
  manifest="$(mktemp)"
  outcome_file="$(mktemp)"
  out_file="$(mktemp)"
  step_file="$(mktemp)"
  printf 'demo-all-pass: [\n' >"${manifest}"

  local actual_exit=0
  LINT_GROUPS_OVERRIDE="${manifest}" \
    GITHUB_STEP_SUMMARY="${step_file}" \
    "${SCRIPT}" demo-all-pass >"${out_file}" 2>&1 || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record 'unparsable manifest' 'cannot read group' \
    "${outcome_file}" "${out_file}" "${step_file}"

  if [[ ${actual_exit} -ne 2 ]]; then
    printf 'FAIL: unparsable manifest — expected exit 2, got %d\n' "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- 'cannot read group' "${out_file}"; then
    printf 'FAIL: unparsable manifest — output missing the diagnostic\n' >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: unparsable manifest -> exit 2\n'
  fi
  rm --force -- "${manifest}" "${outcome_file}" "${out_file}" "${step_file}"
}

function main() {
  run_scenario 'all checks pass -> exit 0' 'demo-all-pass' 0 '| ccc | pass |'
  run_scenario 'one check fails -> exit 1' 'demo-one-fail' 1 '| bbb | FAIL |'
  # don't-abort: zzz must still appear in the table after fff failed
  run_scenario 'failing check does not abort the rest' 'demo-first-fail' 1 '| zzz | pass |'
  run_scenario 'missing script -> exit 1' 'demo-missing' 1 '| nope | FAIL |'
  CHECK_WORKERS_OVERRIDE=3 run_scenario 'parallel run keeps manifest order' 'demo-reverse' 0 'fast-body'
  run_scenario 'unknown group -> exit 2' 'no-such-group' 2 ''
  # A group name is data, never expression text. Each name below closes
  # a quoted segment if spliced into the manifest read: it would run
  # another group, or print an environment variable or a file through
  # `error()`. Read as data, each is a group the manifest does not hold,
  # and a manifest key holding a quote is a group like any other.
  local probe_dir
  probe_dir="$(mktemp -d)"
  printf 'FILE_READ_MARK\n' >"${probe_dir}/probe.txt"
  run_scenario 'group name as data: reads another group' 'nope" // ."demo-one-fail' 2 \
    'unknown or empty group: nope" // ."demo-one-fail' 'unknown or empty group: nope" // ."demo-one-fail'
  PROBE=PAYLOAD_RAN run_scenario 'group name as data: reads env' 'x" | error(strenv(PROBE)) | ."y' 2 \
    'unknown or empty group: x" | error(strenv(PROBE)) | ."y' 'unknown or empty group: x" | error(strenv(PROBE)) | ."y'
  PROBE_FILE="${probe_dir}/probe.txt" run_scenario 'group name as data: reads a file' \
    'x" | error(load_str(strenv(PROBE_FILE))) | ."y' 2 \
    'unknown or empty group: x" | error(load_str(strenv(PROBE_FILE))) | ."y' \
    'unknown or empty group: x" | error(load_str(strenv(PROBE_FILE))) | ."y'
  # A name is looked up by its exact text: `*` is no wildcard. Read as a
  # pattern, it would run every group.
  run_scenario 'group name as data: a wildcard' '*' 2 'unknown or empty group: *' 'unknown or empty group: *'
  rm --recursive --force -- "${probe_dir}"
  run_scenario 'group name as data: a quote in a manifest key' 'q"x' 0 '| qqq | pass |'
  # A group a merge key brings in is found, and of a group written twice
  # the last is run, as yq's own lookup reads them.
  MANIFEST_EXTRA=$'x-base: &base\n  merged:\n    - mmm\n<<: *base\n' \
    run_scenario 'group name as data: through a merge key' 'merged' 0 '| mmm | pass |'
  run_scenario 'group name as data: written twice' 'twice' 0 '| ddd | pass |'
  # A manifest that is not one map of groups is a config error naming the
  # manifest, not an unknown group.
  MANIFEST_BODY=$'- demo-all-pass:\n    - aaa\n' \
    run_scenario 'manifest that is a list' 'demo-all-pass' 2 \
    'the manifest must be one map of groups (got seq)'
  run_test_gate_scenario
  run_unparsable_manifest_scenario

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d scenario(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
