#!/usr/bin/env bash
# tests/docs-audit-pressure.test.sh
#
# Behaviour harness for scripts/docs-audit-pressure.sh.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/docs-audit-pressure.sh"

failures=0

# @description Build a throwaway git repo with workflows + lint-groups, run
#              the script against it, assert exit code and stdout contents.
# @arg $1 scenario name
# @arg $2 expected exit code
# @arg $3 expected stdout substring (empty skips)
# @arg $4 substring that must NOT appear in stdout (empty skips)
function run_scenario() {
  local -r name="$1"
  local -r expected_exit="$2"
  local -r expect_sub="$3"
  local -r forbid_sub="$4"

  local out_file actual_exit=0
  out_file="$(mktemp)"

  WINDOW_DAYS_OVERRIDE="${WINDOW_DAYS:-31}" \
    WORKFLOWS_DIR_OVERRIDE="${WF_DIR}" \
    LINT_GROUPS_OVERRIDE="${LG_FILE}" \
    "${SCRIPT}" >"${out_file}" 2>/dev/null || actual_exit=$?

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
    return
  fi
  if [[ -n ${expect_sub} ]] && ! grep --fixed-strings --quiet -- "${expect_sub}" "${out_file}"; then
    printf 'FAIL: %s — stdout missing %q\n' "${name}" "${expect_sub}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
    return
  fi
  if [[ -n ${forbid_sub} ]] && grep --fixed-strings --quiet -- "${forbid_sub}" "${out_file}"; then
    printf 'FAIL: %s — stdout must not contain %q\n' "${name}" "${forbid_sub}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
    return
  fi
  printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
}

# @description Create a scratch git repo; export WF_DIR / LG_FILE / SANDBOX.
function make_sandbox() {
  SANDBOX="$(mktemp -d)"
  WF_DIR="${SANDBOX}/.github/workflows"
  LG_FILE="${SANDBOX}/.github/lint-groups.yml"
  mkdir -p "${WF_DIR}"
  git -C "${SANDBOX}" init --quiet
  git -C "${SANDBOX}" config user.email t@t.t
  git -C "${SANDBOX}" config user.name t
  printf 'lint-a:\n  - alpha\n' >"${LG_FILE}"
  printf 'name: a\njobs:\n  build:\n    runs-on: x\n' >"${WF_DIR}/a.yml"
  git -C "${SANDBOX}" add -A
  # Backdate the baseline well outside the window. GIT_AUTHOR_DATE /
  # GIT_COMMITTER_DATE only accept strict formats (unix timestamp + tz
  # offset, RFC2822, ISO); fuzzy approxidate strings like "90 days ago"
  # are rejected as env vars even though `git commit --date=` accepts them.
  local -r backdate_ts="$(date -d '90 days ago' '+%s') +0000"
  GIT_AUTHOR_DATE="${backdate_ts}" GIT_COMMITTER_DATE="${backdate_ts}" \
    git -C "${SANDBOX}" commit --quiet -m baseline
}

# --- scenario: quiet window -> pressure 0 ---
make_sandbox
cd "${SANDBOX}"
run_scenario 'quiet window reports zero pressure' 0 'PRESSURE=0' ''

# --- scenario: job added inside window ---
printf 'name: a\njobs:\n  build:\n    runs-on: x\n  publish:\n    runs-on: x\n' >"${WF_DIR}/a.yml"
git -C "${SANDBOX}" add -A
git -C "${SANDBOX}" commit --quiet -m 'ci: add publish job'
run_scenario 'job added is reported' 0 'publish' ''
run_scenario 'non-zero pressure reported' 0 'PRESSURE=1' 'PRESSURE=0'

# --- scenario: commit subjects never leak into the body ---
run_scenario 'commit subject absent from body' 0 '' 'ci: add publish job'

# --- scenario: lint-group member added ---
printf 'lint-a:\n  - alpha\n  - beta\n' >"${LG_FILE}"
git -C "${SANDBOX}" add -A
git -C "${SANDBOX}" commit --quiet -m 'ci: add beta member'
run_scenario 'lint-group member added is reported' 0 'beta' ''

# --- scenario: malformed job id dropped from body ---
printf 'name: a\njobs:\n  build:\n    runs-on: x\n  "Bad Job":\n    runs-on: x\n' >"${WF_DIR}/a.yml"
git -C "${SANDBOX}" add -A
git -C "${SANDBOX}" commit --quiet -m 'ci: add malformed job'
run_scenario 'malformed job id dropped from body' 0 '' 'Bad Job'

# --- scenario: missing workflows dir -> exit 2 ---
WF_DIR="${SANDBOX}/nope"
run_scenario 'missing workflows dir fails loudly' 2 '' ''

# @description Fresh sandbox whose backdated baseline already contains the
#              job + member that a within-window commit then removes, so the
#              removal render paths fire (removals are computed against the
#              backdated boundary, not the previous commit).
function make_removal_sandbox() {
  SANDBOX="$(mktemp -d)"
  WF_DIR="${SANDBOX}/.github/workflows"
  LG_FILE="${SANDBOX}/.github/lint-groups.yml"
  mkdir -p "${WF_DIR}"
  git -C "${SANDBOX}" init --quiet
  git -C "${SANDBOX}" config user.email t@t.t
  git -C "${SANDBOX}" config user.name t
  printf 'lint-a:\n  - alpha\n  - beta\n' >"${LG_FILE}"
  printf 'name: a\njobs:\n  build:\n    runs-on: x\n  publish:\n    runs-on: x\n' >"${WF_DIR}/a.yml"
  git -C "${SANDBOX}" add -A
  local -r backdate_ts="$(date -d '90 days ago' '+%s') +0000"
  GIT_AUTHOR_DATE="${backdate_ts}" GIT_COMMITTER_DATE="${backdate_ts}" \
    git -C "${SANDBOX}" commit --quiet -m baseline
  # Within-window commit removes publish job and beta member.
  printf 'lint-a:\n  - alpha\n' >"${LG_FILE}"
  printf 'name: a\njobs:\n  build:\n    runs-on: x\n' >"${WF_DIR}/a.yml"
  git -C "${SANDBOX}" add -A
  git -C "${SANDBOX}" commit --quiet -m 'ci: remove publish job and beta member'
}

# --- scenario: job + member removed inside window ---
make_removal_sandbox
cd "${SANDBOX}"
run_scenario 'removed job is reported' 0 'Jobs removed:' ''
run_scenario 'removed job id rendered' 0 'publish' ''
run_scenario 'removed member is reported' 0 'Lint-group members removed:' ''
run_scenario 'removed member id rendered' 0 'beta' ''

cd "${REPO_ROOT}"

if ((failures)); then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
