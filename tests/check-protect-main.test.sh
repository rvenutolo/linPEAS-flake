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
function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"

  local stderr_file
  stderr_file="$(mktemp)"

  local actual_exit=0
  RULESET_JSON_OVERRIDE="${FIXTURES}/${fixture_dir}/live.json" \
    MIRROR_JSON_OVERRIDE="${FIXTURES}/${fixture_dir}/mirror.json" \
    DOC_TABLE_OVERRIDE="${FIXTURES}/${fixture_dir}/required-checks.md" \
    "${SCRIPT}" >/dev/null 2>"${stderr_file}" || actual_exit=$?
  harness_assert_record "${name}" "${expected_stderr}" "${stderr_file}"

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

  rm --force -- "${stderr_file}"
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
  run_scenario 'non-array rules is a tooling error' \
    'bad-rules-wrong-type' 2 \
    'protect-main ruleset: could not read .rules[].type'

  # The no-op-ruleset guard (fetch_ruleset hard-fails when the live
  # ruleset id is empty) is unreachable through run_scenario, which always
  # sets RULESET_JSON_OVERRIDE. Exercise it directly: stub `gh` to return
  # an empty ruleset list (empty id) and run the live path with only the
  # mirror + doc overrides.
  local gh_stub_dir stderr_file no_op_exit=0
  gh_stub_dir="$(mktemp --directory)"
  stderr_file="$(mktemp)"
  printf '#!/usr/bin/env bash\nprintf ""\n' >"${gh_stub_dir}/gh"
  chmod +x "${gh_stub_dir}/gh"
  PATH="${gh_stub_dir}:${PATH}" \
    MIRROR_JSON_OVERRIDE="${FIXTURES}/good/mirror.json" \
    DOC_TABLE_OVERRIDE="${FIXTURES}/good/required-checks.md" \
    "${SCRIPT}" >/dev/null 2>"${stderr_file}" || no_op_exit=$?
  harness_assert_record 'no-op-ruleset guard' 'no ruleset named protect-main' \
    "${stderr_file}"
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
  rm --recursive --force -- "${gh_stub_dir}" "${stderr_file}"
  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
