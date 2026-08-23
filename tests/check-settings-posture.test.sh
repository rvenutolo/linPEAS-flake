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
# @arg $5 repo payload filename under the fixture subdir (default
#   repo.json) — a scenario whose payload must stay invalid JSON names a
#   non-.json file here so prettier's `*.json` include never touches it
function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"
  local -r repo_file="${5:-repo.json}"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  REPO_JSON_OVERRIDE="${FIXTURES}/${fixture_dir}/${repo_file}" \
    ACTIONS_PERMS_JSON_OVERRIDE="${FIXTURES}/${fixture_dir}/actions-perms.json" \
    ACTIONS_WORKFLOW_PERMS_JSON_OVERRIDE="${FIXTURES}/${fixture_dir}/actions-workflow-perms.json" \
    ENV_GITHUB_PAGES_JSON_OVERRIDE="${FIXTURES}/${fixture_dir}/env-github-pages.json" \
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

# Points one override at an unreadable payload while the other three keep
# the good fixtures, so a scenario proves the could-not-run path fires on
# the override under test and nowhere else. Mode bits are no lever for
# root, so this scenario is skipped there.
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

  local repo_override="${FIXTURES}/good/repo.json"
  local actions_perms_override="${FIXTURES}/good/actions-perms.json"
  local actions_workflow_perms_override="${FIXTURES}/good/actions-workflow-perms.json"
  local env_github_pages_override="${FIXTURES}/good/env-github-pages.json"
  case "${override_var}" in
  REPO_JSON_OVERRIDE) repo_override="${payload}" ;;
  ACTIONS_PERMS_JSON_OVERRIDE) actions_perms_override="${payload}" ;;
  ACTIONS_WORKFLOW_PERMS_JSON_OVERRIDE) actions_workflow_perms_override="${payload}" ;;
  ENV_GITHUB_PAGES_JSON_OVERRIDE) env_github_pages_override="${payload}" ;;
  esac

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  REPO_JSON_OVERRIDE="${repo_override}" \
    ACTIONS_PERMS_JSON_OVERRIDE="${actions_perms_override}" \
    ACTIONS_WORKFLOW_PERMS_JSON_OVERRIDE="${actions_workflow_perms_override}" \
    ENV_GITHUB_PAGES_JSON_OVERRIDE="${env_github_pages_override}" \
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

# @description Run the lint against a live `gh` that is present and
# fails, with no payload override, so the fetch itself is the fault. An
# unchecked fetch would hand `gh`'s own exit 1 to the caller, which reads
# as settings-posture drift.
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
  # A malformed repo payload is a could-not-run, not drift or a raw jq
  # crash: each scenario reuses the good actions-perms/workflow-perms/
  # env-github-pages fixtures and varies only the repo payload, naming
  # the source kind rather than the fixture path.
  run_scenario 'empty repo payload is a tooling error' \
    'bad-repo-empty' 2 'empty payload from REPO_JSON_OVERRIDE'
  run_scenario 'repo payload that is not JSON is a tooling error' \
    'bad-repo-not-json' 2 'payload from REPO_JSON_OVERRIDE is not valid JSON' \
    'repo-payload.txt'
  run_scenario 'boolean-typed repo payload is a tooling error' \
    'bad-repo-wrong-type' 2 \
    'unexpected payload shape from REPO_JSON_OVERRIDE: payload is boolean, want object'

  # This is the reported defect: an unreadable override payload must
  # report a could-not-run (exit 2), not a raw `cat` failure under exit 1.
  # One scenario per override that reads through fetch_json_override_into
  # — each names its own override variable, so the four sentences are
  # distinguishable without needing a subject.
  run_unreadable_scenario 'unreadable repo override is a tooling error, not drift' \
    REPO_JSON_OVERRIDE \
    'payload from REPO_JSON_OVERRIDE is not readable'
  run_unreadable_scenario 'unreadable actions-permissions override is a tooling error, not drift' \
    ACTIONS_PERMS_JSON_OVERRIDE \
    'payload from ACTIONS_PERMS_JSON_OVERRIDE is not readable'
  run_unreadable_scenario 'unreadable actions-workflow-permissions override is a tooling error, not drift' \
    ACTIONS_WORKFLOW_PERMS_JSON_OVERRIDE \
    'payload from ACTIONS_WORKFLOW_PERMS_JSON_OVERRIDE is not readable'
  run_unreadable_scenario 'unreadable github-pages environment override is a tooling error, not drift' \
    ENV_GITHUB_PAGES_JSON_OVERRIDE \
    'payload from ENV_GITHUB_PAGES_JSON_OVERRIDE is not readable'

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

  # A `gh` that is present and fails is a fetch that never happened, not
  # posture that drifted: exit 2, and a diagnostic naming the call.
  run_failing_gh_scenario 'failing gh is a tooling error, not posture drift' \
    'GitHub API call failed'
  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
