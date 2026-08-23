#!/usr/bin/env bash
# tests/check-protect-main.test.sh
#
# Failure-mode harness for scripts/check-protect-main.sh.
# Mirrors tests/check-tag-protection.test.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-protect-main.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-protect-main"

failures=0

# @arg $1 scenario name
# @arg $2 fixture subdir
# @arg $3 expected exit (0 pass, 1 drift, 2 tooling error)
# @arg $4 expected stderr substring (empty skips)
# @arg $5 ruleset payload filename under the fixture subdir (default
#   live.json) — a scenario whose payload must stay invalid JSON names a
#   non-.json file here so prettier's `*.json` include never touches it
function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"
  local -r ruleset_file="${5:-live.json}"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  PROTECT_MAIN_RULESET_JSON_OVERRIDE="${FIXTURES}/${fixture_dir}/${ruleset_file}" \
    MIRROR_JSON_OVERRIDE="${FIXTURES}/${fixture_dir}/mirror.json" \
    DOC_TABLE_OVERRIDE="${FIXTURES}/${fixture_dir}/required-checks.md" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
}

# Points one override at an unreadable payload while the other two keep
# the good fixtures, so a scenario proves the could-not-run path fires on
# the override under test and nowhere else. Mode bits are no lever for
# root, so this scenario is skipped there; run_directory_scenario below
# covers the same class for every user including root.
# @arg $1 scenario name
# @arg $2 override variable to point at the unreadable payload
# @arg $3 expected stderr substring
function run_unreadable_scenario() {
  local -r name="$1" override_var="$2" expected_stderr="$3"
  if [[ ${EUID} -eq 0 ]]; then
    printf 'SKIP: %s (running as root — mode bits are no lever)\n' "${name}"
    return 0
  fi
  local payload
  payload="$(mktemp)"
  printf '{}' >"${payload}"
  chmod 000 -- "${payload}"

  local ruleset_override="${FIXTURES}/good/live.json"
  local mirror_override="${FIXTURES}/good/mirror.json"
  local doc_override="${FIXTURES}/good/required-checks.md"
  case "${override_var}" in
  PROTECT_MAIN_RULESET_JSON_OVERRIDE) ruleset_override="${payload}" ;;
  MIRROR_JSON_OVERRIDE) mirror_override="${payload}" ;;
  DOC_TABLE_OVERRIDE) doc_override="${payload}" ;;
  esac

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  PROTECT_MAIN_RULESET_JSON_OVERRIDE="${ruleset_override}" \
    MIRROR_JSON_OVERRIDE="${mirror_override}" \
    DOC_TABLE_OVERRIDE="${doc_override}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"

  if [[ ${actual_exit} -ne 2 ]]; then
    printf 'FAIL: %s — expected exit 2, got %d\n' "${name}" "${actual_exit}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
  chmod 600 -- "${payload}"
  rm --force -- "${payload}"
}

# Points one override at a directory instead of a file. A directory fails
# the read for every user, root included — no mode bits stand between it
# and the could-not-run path — so this scenario keeps that path proven
# even when run_unreadable_scenario above self-skips.
# @arg $1 scenario name
# @arg $2 override variable to point at the directory
# @arg $3 expected stderr substring
function run_directory_scenario() {
  local -r name="$1" override_var="$2" expected_stderr="$3"
  local payload
  payload="$(mktemp --directory)"

  local ruleset_override="${FIXTURES}/good/live.json"
  local mirror_override="${FIXTURES}/good/mirror.json"
  local doc_override="${FIXTURES}/good/required-checks.md"
  case "${override_var}" in
  PROTECT_MAIN_RULESET_JSON_OVERRIDE) ruleset_override="${payload}" ;;
  MIRROR_JSON_OVERRIDE) mirror_override="${payload}" ;;
  DOC_TABLE_OVERRIDE) doc_override="${payload}" ;;
  esac

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  PROTECT_MAIN_RULESET_JSON_OVERRIDE="${ruleset_override}" \
    MIRROR_JSON_OVERRIDE="${mirror_override}" \
    DOC_TABLE_OVERRIDE="${doc_override}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"

  if [[ ${actual_exit} -ne 2 ]]; then
    printf 'FAIL: %s — expected exit 2, got %d\n' "${name}" "${actual_exit}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
  rm --recursive --force -- "${payload}"
}

# @description Run the lint against a live `gh` that is present and
# fails, with no ruleset override, so the fetch itself is the fault. An
# unchecked fetch would hand `gh`'s own exit 1 to the caller, which reads
# as a drifted ruleset; the mirror and doc overrides point at the good
# fixture so the doc-table half passes and the run reaches the fetch.
# @arg $1 scenario name  @arg $2 expected stderr substring
function run_failing_gh_scenario() {
  local -r name="$1"
  local -r expected_stderr="$2"

  local shim_dir
  shim_dir="$(mktemp --directory)"
  printf '#!/usr/bin/env bash\nexit 1\n' >"${shim_dir}/gh"
  chmod +x -- "${shim_dir}/gh"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  PATH="${shim_dir}:${PATH}" \
    MIRROR_JSON_OVERRIDE="${FIXTURES}/good/mirror.json" \
    DOC_TABLE_OVERRIDE="${FIXTURES}/good/required-checks.md" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"

  if [[ ${actual_exit} -ne 2 ]]; then
    printf 'FAIL: %s — expected exit 2, got %d\n' "${name}" "${actual_exit}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
  rm --recursive --force -- "${shim_dir}"
}

function main() {
  run_scenario 'matching live + mirror passes' \
    'good' 0 ''
  run_scenario 'wrong ruleset name fails' \
    'bad-name' 1 'name drift'
  run_scenario 'non-merge allowed methods fails' \
    'bad-wrong-merge' 1 'allowed_merge_methods drift'
  run_scenario 'required-checks drift fails' \
    'bad-required-checks-drift' 1 'required-status-checks drift'
  run_scenario 'integration_id drift fails' \
    'bad-integration-id-drift' 1 'integration_id drift'
  run_scenario 'doc-table drift fails' \
    'bad-doc-table-drift' 1 'doc-table drift'
  run_scenario 'non-empty bypass_actors fails' \
    'bad-bypass-actors' 1 'bypass_actors non-empty'
  run_scenario 'missing required_signatures rule fails' \
    'bad-missing-rule' 1 'missing rule: required_signatures'
  run_scenario 'strict policy false fails' \
    'bad-strict-false' 1 'strict_required_status_checks_policy drift'
  run_scenario 'thread-resolution false fails' \
    'bad-thread-resolution-false' 1 'required_review_thread_resolution drift'
  run_scenario 'disabled enforcement fails' \
    'bad-enforcement-drift' 1 'enforcement drift'
  run_scenario 'wrong target fails' \
    'bad-target-drift' 1 'target drift'
  run_scenario 'ref_name include drift fails' \
    'bad-ref-name-drift' 1 'conditions.ref_name.include drift'
  run_scenario 'empty rules list is drift, not a tooling error' \
    'bad-rules-empty' 1 'missing rule: deletion (have: )'
  # Two layers reject a malformed `.rules`, so both need a scenario. The
  # up-front shape gate rejects a `.rules` that is not an array at all. An
  # array holding non-objects passes that gate, and the capture guard around
  # `.rules[].type` is the only thing that catches it — which is why that
  # guard stays even though the gate stands in front of it.
  run_scenario 'non-array rules is a tooling error' \
    'bad-rules-wrong-type' 2 \
    'protect-main ruleset: unexpected payload shape from PROTECT_MAIN_RULESET_JSON_OVERRIDE: .rules is string, want array'
  run_scenario 'rules holding non-objects is a tooling error' \
    'bad-rules-non-object-items' 2 \
    'protect-main ruleset: could not read .rules[].type'
  # Absent inputs are read failures, not posture drift: with no mirror
  # there is nothing to compare the live ruleset against.
  run_scenario 'absent mirror is a tooling error' \
    'no-such-fixture' 2 'protect-main mirror: payload from MIRROR_JSON_OVERRIDE not found'
  # A malformed ruleset payload is a could-not-run, not drift or a raw
  # jq crash: the doc-table check above already proved mirror/doc parity
  # runs before the live ruleset is even fetched, so these three reuse
  # the good mirror and doc fixtures and vary only live.json.
  run_scenario 'empty ruleset payload is a tooling error' \
    'bad-ruleset-empty' 2 'protect-main ruleset: empty payload from PROTECT_MAIN_RULESET_JSON_OVERRIDE'
  run_scenario 'ruleset payload that is not JSON is a tooling error' \
    'bad-ruleset-not-json' 2 \
    'protect-main ruleset: payload from PROTECT_MAIN_RULESET_JSON_OVERRIDE is not valid JSON' \
    'live-payload.txt'
  run_scenario 'boolean-typed ruleset payload is a tooling error' \
    'bad-ruleset-wrong-type' 2 \
    'protect-main ruleset: unexpected payload shape from PROTECT_MAIN_RULESET_JSON_OVERRIDE: payload is boolean, want object'

  # This is the reported defect: an unreadable payload must report a
  # could-not-run (exit 2), not drift (exit 1). One scenario per override
  # that reads through the JSON helper, plus the doc table's own guard.
  run_unreadable_scenario 'unreadable ruleset override is a tooling error, not drift' \
    PROTECT_MAIN_RULESET_JSON_OVERRIDE \
    'protect-main ruleset: payload from PROTECT_MAIN_RULESET_JSON_OVERRIDE is not readable'
  run_unreadable_scenario 'unreadable mirror override is a tooling error, not drift' \
    MIRROR_JSON_OVERRIDE \
    'protect-main mirror: payload from MIRROR_JSON_OVERRIDE is not readable'
  run_unreadable_scenario 'unreadable doc table override is a tooling error, not drift' \
    DOC_TABLE_OVERRIDE \
    'required-checks doc is not readable:'
  # A directory passes both the existence and (typically) the readable
  # checks, so it proves the could-not-run path for every user, root
  # included, where the unreadable scenario above self-skips.
  run_directory_scenario 'directory-payload ruleset override is a tooling error, not drift' \
    PROTECT_MAIN_RULESET_JSON_OVERRIDE \
    'protect-main ruleset: payload from PROTECT_MAIN_RULESET_JSON_OVERRIDE could not be read'

  # The no-op-ruleset guard (fetch_ruleset hard-fails when the live
  # ruleset id is empty) is unreachable through run_scenario, which always
  # sets PROTECT_MAIN_RULESET_JSON_OVERRIDE. Exercise it directly: stub
  # `gh` to return an empty ruleset list (empty id) and run the live path
  # with only the mirror + doc overrides.
  local gh_stub_dir stderr_file stdout_file outcome_file no_op_exit=0
  gh_stub_dir="$(mktemp --directory)"
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"
  printf '#!/usr/bin/env bash\nprintf ""\n' >"${gh_stub_dir}/gh"
  chmod +x "${gh_stub_dir}/gh"
  PATH="${gh_stub_dir}:${PATH}" \
    MIRROR_JSON_OVERRIDE="${FIXTURES}/good/mirror.json" \
    DOC_TABLE_OVERRIDE="${FIXTURES}/good/required-checks.md" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || no_op_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${no_op_exit}" >"${outcome_file}"
  harness_assert_record 'no-op-ruleset guard' 'no ruleset named protect-main' \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  if [[ ${no_op_exit} -ne 1 ]]; then
    printf 'FAIL: no-op-ruleset guard — expected exit 1, got %d\n' "${no_op_exit}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- 'no ruleset named protect-main' "${stderr_file}"; then
    printf 'FAIL: no-op-ruleset guard — stderr missing %q\n' 'no ruleset named protect-main' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: no-op-ruleset guard fires on empty ruleset id\n'
  fi
  rm --recursive --force -- "${gh_stub_dir}" "${stderr_file}" \
    "${stdout_file}" "${outcome_file}"
  # A `gh` that is present and fails is a fetch that never happened, not a
  # ruleset that drifted: exit 2, and a diagnostic naming the call.
  run_failing_gh_scenario 'failing gh is a tooling error, not drift' \
    'cannot list rulesets for'
  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
