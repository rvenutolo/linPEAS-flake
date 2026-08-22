#!/usr/bin/env bash
# tests/mark-docs-audit.test.sh
#
# Behaviour harness for scripts/mark-docs-audit.sh.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/mark-docs-audit.sh"

failures=0

# @description Run the script against the sandbox once and record that
#              invocation as a single scenario carrying every asserted
#              substring.
# @arg $1 scenario name
# @arg $2 expected exit code
# @arg $@ `--expect <substring>` (stdout), `--expect-err <substring>`
#         (stderr), each repeatable
function run_scenario() {
  local -r name="$1"
  local -r expected_exit="$2"
  shift 2

  local -a expect_subs=() expect_err_subs=()
  while (($#)); do
    case "$1" in
    --expect)
      expect_subs+=("$2")
      shift 2
      ;;
    --expect-err)
      expect_err_subs+=("$2")
      shift 2
      ;;
    *)
      printf 'FAIL: %s — run_scenario got unknown argument %q\n' "${name}" "$1" >&2
      exit 1
      ;;
    esac
  done

  local out_file err_file outcome_file actual_exit=0
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  outcome_file="$(mktemp)"

  DOCS_AUDIT_STATE_OVERRIDE="${STATE_FILE}" \
    REF_OVERRIDE="${REF:-HEAD}" \
    "${SCRIPT}" >"${out_file}" 2>"${err_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"

  local sub
  local -a all_subs=("${expect_subs[@]}" "${expect_err_subs[@]}")
  harness_assert_record "${name}" "${all_subs[0]-}" \
    "${outcome_file}" "${out_file}" "${err_file}"
  for sub in "${all_subs[@]:1}"; do
    harness_assert_also "${sub}"
  done

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${out_file}" "${err_file}" >&2
    failures=$((failures + 1))
    return
  fi
  for sub in "${expect_subs[@]}"; do
    if ! grep --fixed-strings --quiet -- "${sub}" "${out_file}"; then
      printf 'FAIL: %s — stdout missing %q\n' "${name}" "${sub}" >&2
      cat -- "${out_file}" >&2
      failures=$((failures + 1))
      return
    fi
  done
  for sub in "${expect_err_subs[@]}"; do
    if ! grep --fixed-strings --quiet -- "${sub}" "${err_file}"; then
      printf 'FAIL: %s — stderr missing %q\n' "${name}" "${sub}" >&2
      cat -- "${err_file}" >&2
      failures=$((failures + 1))
      return
    fi
  done
  printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
}

# @description Create a scratch git repo with one commit; export SANDBOX,
#              STATE_FILE and HEAD_SHA.
function make_sandbox() {
  SANDBOX="$(mktemp --directory)"
  STATE_FILE="${SANDBOX}/.github/docs-audit-state"
  mkdir --parents "${SANDBOX}/.github"
  git -C "${SANDBOX}" init --quiet
  git -C "${SANDBOX}" config user.email t@t.t
  git -C "${SANDBOX}" config user.name t
  printf 'x\n' >"${SANDBOX}/f"
  git -C "${SANDBOX}" add --all
  git -C "${SANDBOX}" commit --quiet -m baseline
  HEAD_SHA="$(git -C "${SANDBOX}" rev-parse HEAD)"
}

make_sandbox
cd "${SANDBOX}"

# --- scenario: records HEAD, and the marker the pressure script parses ---
# One invocation asserts the confirmation line, the recorded sha, and the
# fact that the sha reached the file in the LAST_AUDIT_SHA=<sha> shape the
# pressure script's parser requires.
run_scenario 'records the current commit as the audit point' 0 \
  --expect 'recorded audit point' --expect "${HEAD_SHA}"

if ! grep --quiet --line-regexp "LAST_AUDIT_SHA=${HEAD_SHA}" "${STATE_FILE}"; then
  printf 'FAIL: marker file lacks LAST_AUDIT_SHA=%s\n' "${HEAD_SHA}" >&2
  cat -- "${STATE_FILE}" >&2
  failures=$((failures + 1))
fi

# --- scenario: the marker the script writes is one the reader accepts ---
# The two scripts are only useful as a pair, so the harness drives the
# reader against the writer's output rather than asserting the shape twice.
readonly PRESSURE="${REPO_ROOT}/scripts/docs-audit-pressure.sh"
mkdir --parents "${SANDBOX}/.github/workflows"
printf 'lint-a:\n  - alpha\n' >"${SANDBOX}/.github/lint-groups.yml"
printf 'name: a\njobs:\n  build:\n    runs-on: x\n' >"${SANDBOX}/.github/workflows/a.yml"
git -C "${SANDBOX}" add --all
git -C "${SANDBOX}" commit --quiet -m 'ci: add a workflow'
REF_OVERRIDE=HEAD DOCS_AUDIT_STATE_OVERRIDE="${STATE_FILE}" "${SCRIPT}" >/dev/null
pressure_out="$(
  DOCS_AUDIT_STATE_OVERRIDE="${STATE_FILE}" \
    WORKFLOWS_DIR_OVERRIDE="${SANDBOX}/.github/workflows" \
    LINT_GROUPS_OVERRIDE="${SANDBOX}/.github/lint-groups.yml" \
    "${PRESSURE}"
)"
if ! grep --fixed-strings --quiet -- 'PRESSURE=0' <<<"${pressure_out}"; then
  printf 'FAIL: pressure script did not read the written marker as zero drift\n' >&2
  printf '%s\n' "${pressure_out}" >&2
  failures=$((failures + 1))
else
  printf 'PASS: written marker reads back as zero pressure (exit 0)\n'
fi

# --- scenario: a ref that names no commit here ---
REF=0000000000000000000000000000000000000000
run_scenario 'unresolvable ref fails loudly' 2 \
  --expect-err 'cannot resolve'
unset REF

# --- scenario: target directory does not exist ---
STATE_FILE="${SANDBOX}/nope/docs-audit-state"
run_scenario 'unwritable target directory fails loudly' 2 \
  --expect-err 'is not a directory'

cd "${REPO_ROOT}"

harness_assert_verify || failures=$((failures + 1))

if ((failures)); then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
