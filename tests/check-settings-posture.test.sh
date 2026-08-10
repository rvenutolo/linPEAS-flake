#!/usr/bin/env bash
# tests/check-settings-posture.test.sh
#
# Failure-mode harness for scripts/check-settings-posture.sh.
# Mirrors tests/check-protect-main.test.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-settings-posture.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-settings-posture"

failures=0

# @arg $1 scenario name
# @arg $2 fixture subdir
# @arg $3 expected exit
# @arg $4 expected stderr substring (empty skips)
function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"

  local stderr_file
  stderr_file="$(mktemp)"

  local actual_exit=0
  REPO_JSON_OVERRIDE="${FIXTURES}/${fixture_dir}/repo.json" \
    ACTIONS_PERMS_JSON_OVERRIDE="${FIXTURES}/${fixture_dir}/actions-perms.json" \
    ACTIONS_WORKFLOW_PERMS_JSON_OVERRIDE="${FIXTURES}/${fixture_dir}/actions-workflow-perms.json" \
    ENV_GITHUB_PAGES_JSON_OVERRIDE="${FIXTURES}/${fixture_dir}/env-github-pages.json" \
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
  # The bad-multiple fixture deliberately drifts default_workflow_permissions
  # alongside two other settings, so the single-setting fixture's drift line is
  # byte-identical to one of the three lines bad-multiple emits. The assertion
  # still separates this scenario from the passing fixture and from every other
  # single-drift fixture.
  harness_assert_exempt 'default_workflow_permissions drift: got write, want read' \
    'multiple simultaneous drifts surface all' \
    'the multi-drift fixture includes this same drift by design'

  run_scenario 'matching fixtures pass' \
    'good' 0 ''
  run_scenario 'secret-scanning disabled fails' \
    'bad-secret-scanning-off' 1 'secret_scanning.status drift'
  run_scenario 'default workflow permissions write fails' \
    'bad-default-perms-write' 1 'default_workflow_permissions drift: got write, want read'
  run_scenario 'github-pages env can_admins_bypass true fails' \
    'bad-admins-bypass' 1 'environments.github-pages.can_admins_bypass drift'
  run_scenario 'multiple simultaneous drifts surface all' \
    'bad-multiple' 1 'can_approve_pull_request_reviews drift'
  run_scenario 'push-protection disabled fails' \
    'bad-push-protection-off' 1 'secret_scanning_push_protection.status drift'
  run_scenario 'dependabot updates disabled fails' \
    'bad-dependabot-off' 1 'dependabot_security_updates.status drift'
  run_scenario 'allowed_actions all fails' \
    'bad-allowed-actions-all' 1 'allowed_actions drift'

  # Multi-drift scenario must surface every drift in a single run, not
  # stop at the first. This is asserted by counting drift lines in
  # stderr — should be >=3 for bad-multiple (sha_pinning_required,
  # default_workflow_permissions, can_approve_pull_request_reviews).
  local stderr_file
  stderr_file="$(mktemp)"
  REPO_JSON_OVERRIDE="${FIXTURES}/bad-multiple/repo.json" \
    ACTIONS_PERMS_JSON_OVERRIDE="${FIXTURES}/bad-multiple/actions-perms.json" \
    ACTIONS_WORKFLOW_PERMS_JSON_OVERRIDE="${FIXTURES}/bad-multiple/actions-workflow-perms.json" \
    ENV_GITHUB_PAGES_JSON_OVERRIDE="${FIXTURES}/bad-multiple/env-github-pages.json" \
    "${SCRIPT}" >/dev/null 2>"${stderr_file}" || true
  local drift_lines
  drift_lines="$(grep --count -- ' drift: ' "${stderr_file}" || true)"
  if ((drift_lines < 3)); then
    printf 'FAIL: bad-multiple — expected >=3 drift lines, got %d\n' \
      "${drift_lines}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: bad-multiple surfaces %d drift lines in one run\n' \
      "${drift_lines}"
  fi
  rm --force -- "${stderr_file}"

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
