#!/usr/bin/env bash
# tests/check-patch-tag-pins.test.sh

set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-patch-tag-pins.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-patch-tag-pins"

# One message per failure mode, so a fixture that regresses into a
# different mode is reported as a mismatch instead of passing.
readonly MSG_NO_COMMENT="pin carries no version comment"
readonly MSG_NO_VERSION="pin comment names no version"
readonly MSG_MAJOR="pin comment names a major tag, not an exact patch tag"

failures=0

# @description Run the lint with LINT_PATHS_OVERRIDE set to $2 (one or more
# newline-separated fixture paths), asserting exit code and a stderr
# substring; records the run's whole observable outcome for the
# cross-scenario discrimination gate.
# @arg $1 scenario name  @arg $2 newline-separated fixture paths
# @arg $3 expected exit  @arg $4 expected stderr substring ('' skips)
function run_scenario() {
  local -r name="$1"
  local -r override="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="${4:-}"

  local stdout_file stderr_file outcome_file
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  LINT_PATHS_OVERRIDE="${override}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm --force -- "${stdout_file}" "${stderr_file}" "${outcome_file}"
}

function main() {
  # good.yml, good-exact-pin.yml, and good-exception.yml each exit 0 with
  # empty stdout and stderr — three byte-identical outcomes, so they are one
  # scenario driven off a combined path list rather than three
  # indistinguishable pass lines pretending to be three observations.
  run_scenario 'all-good-shapes' \
    "${FIXTURES}/good.yml"$'\n'"${FIXTURES}/good-exact-pin.yml"$'\n'"${FIXTURES}/good-exception.yml" \
    0 ''

  # bad.yml and bad-floating-major.yml both trip MSG_MAJOR, so each
  # assertion is anchored to its own fixture path — the message text alone
  # would also match the other's output.
  run_scenario 'bad.yml' "${FIXTURES}/bad.yml" 1 "bad.yml:4: ${MSG_MAJOR}"
  run_scenario 'bad-floating-major.yml' "${FIXTURES}/bad-floating-major.yml" \
    1 "bad-floating-major.yml:4: ${MSG_MAJOR}"

  # A SHA pin with no trailing comment at all leaves the intended tag
  # unrecorded, so the SHA cannot be audited against a tag.
  run_scenario 'bad-no-comment.yml' "${FIXTURES}/bad-no-comment.yml" \
    1 "${MSG_NO_COMMENT}"

  # A comment that names something other than a version (a branch, a
  # channel) records no tag either.
  run_scenario 'bad-nonversion-comment.yml' "${FIXTURES}/bad-nonversion-comment.yml" \
    1 "${MSG_NO_VERSION}"

  # Empty reason after `patch-tag-exception:` does not satisfy the exception
  # (a non-whitespace char must follow the colon), so it is still flagged.
  # Anchored to its own path since it also trips MSG_MAJOR.
  run_scenario 'bad-empty-reason.yml' "${FIXTURES}/bad-empty-reason.yml" \
    1 "bad-empty-reason.yml:4: ${MSG_MAJOR}"

  # action.yaml composite via default scan (no LINT_PATHS_OVERRIDE): fixed
  # once the .github/actions discovery covers action.yaml, not just
  # action.yml.
  ACTIONYAML_DIR="$(mktemp --directory)"
  mkdir --parents "${ACTIONYAML_DIR}/.github/actions/sample-yaml"
  cat >"${ACTIONYAML_DIR}/.github/actions/sample-yaml/action.yaml" <<'ACTION_EOF'
name: sample-yaml
runs:
  using: composite
  steps:
    - uses: github/codeql-action/init@03e4368ac7daa2bd82b3e85262f3bf87ee112f57 # v3
ACTION_EOF
  ay_stdout="$(mktemp)"
  ay_stderr="$(mktemp)"
  ay_outcome="$(mktemp)"
  ay_exit=0
  (cd "${ACTIONYAML_DIR}" && "${SCRIPT}") >"${ay_stdout}" 2>"${ay_stderr}" || ay_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${ay_exit}" >"${ay_outcome}"
  harness_assert_record 'action.yaml composite' 'action.yaml' \
    "${ay_outcome}" "${ay_stdout}" "${ay_stderr}"
  if ((ay_exit == 0)); then
    printf 'FAIL action.yaml composite: exit 0, want 1\n' >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- "${MSG_MAJOR}" "${ay_stderr}"; then
    printf 'FAIL action.yaml composite: stderr missing %q\n  got: %s\n' \
      "${MSG_MAJOR}" "$(cat -- "${ay_stderr}")" >&2
    failures=$((failures + 1))
  else
    printf 'OK   action.yaml composite (exit %d)\n' "${ay_exit}"
  fi
  rm --recursive --force -- "${ACTIONYAML_DIR}"
  rm --force -- "${ay_stdout}" "${ay_stderr}" "${ay_outcome}"

  # Default scan against a cwd holding no `.github` at all. Both find roots
  # are relative, so this is what a lint invoked from the wrong directory
  # sees: zero files enumerated. Scored as data that is a silent exit 0 over
  # every pin in the repo, so it has to be a could-not-run instead.
  EMPTY_SCAN_DIR="$(mktemp --directory)"
  es_stdout="$(mktemp)"
  es_stderr="$(mktemp)"
  es_outcome="$(mktemp)"
  es_exit=0
  (cd "${EMPTY_SCAN_DIR}" && "${SCRIPT}") >"${es_stdout}" 2>"${es_stderr}" || es_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${es_exit}" >"${es_outcome}"
  harness_assert_record 'empty scan set' \
    'enumerated 0 workflow / composite-action file(s)' \
    "${es_outcome}" "${es_stdout}" "${es_stderr}"
  if ((es_exit != 2)); then
    printf 'FAIL empty scan set: exit %d, want 2\n  got: %s\n' \
      "${es_exit}" "$(cat -- "${es_stderr}")" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- \
    'enumerated 0 workflow / composite-action file(s)' "${es_stderr}"; then
    printf 'FAIL empty scan set: stderr missing the breadth diagnostic\n' >&2
    failures=$((failures + 1))
  else
    printf 'OK   empty scan set (exit %d)\n' "${es_exit}"
  fi
  rm --recursive --force -- "${EMPTY_SCAN_DIR}"
  rm --force -- "${es_stdout}" "${es_stderr}" "${es_outcome}"

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf 'all tests passed\n'
}

main "$@"
