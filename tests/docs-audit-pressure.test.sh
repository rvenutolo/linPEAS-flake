#!/usr/bin/env bash
# tests/docs-audit-pressure.test.sh
#
# Behaviour harness for scripts/docs-audit-pressure.sh.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/docs-audit-pressure.sh"

failures=0

# @description Build a throwaway git repo with workflows + lint-groups, run
#              the script against it ONCE, and record that invocation as a
#              single scenario carrying every asserted substring. Running the
#              script again per asserted property would produce byte-identical
#              sibling records, which no substring can separate. A substring
#              that must be ABSENT asserts nothing about the output, so it
#              stays a local check and contributes no record.
# @arg $1 scenario name
# @arg $2 expected exit code
# @arg $@ `--expect <substring>` (must appear in stdout),
#         `--expect-err <substring>` (must appear in stderr) and
#         `--forbid <substring>` (must not appear), each repeatable
function run_scenario() {
  local -r name="$1"
  local -r expected_exit="$2"
  shift 2

  local -a expect_subs=() expect_err_subs=() forbid_subs=()
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
    --forbid)
      forbid_subs+=("$2")
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

  WINDOW_DAYS_OVERRIDE="${WINDOW_DAYS:-31}" \
    WORKFLOWS_DIR_OVERRIDE="${WF_DIR}" \
    LINT_GROUPS_OVERRIDE="${LG_FILE}" \
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
    cat -- "${out_file}" >&2
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
  for sub in "${forbid_subs[@]}"; do
    if grep --fixed-strings --quiet -- "${sub}" "${out_file}"; then
      printf 'FAIL: %s — stdout must not contain %q\n' "${name}" "${sub}" >&2
      cat -- "${out_file}" >&2
      failures=$((failures + 1))
      return
    fi
  done
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
run_scenario 'quiet window reports zero pressure' 0 --expect 'PRESSURE=0'

# --- scenario: job added inside window ---
# One report renders the added job, raises the pressure count, and keeps the
# commit subject out of the body, so one invocation asserts all three.
printf 'name: a\njobs:\n  build:\n    runs-on: x\n  publish:\n    runs-on: x\n' >"${WF_DIR}/a.yml"
git -C "${SANDBOX}" add -A
git -C "${SANDBOX}" commit --quiet -m 'ci: add publish job'
run_scenario 'job added is reported with non-zero pressure' 0 \
  --expect 'publish' --expect 'PRESSURE=1' \
  --forbid 'PRESSURE=0' --forbid 'ci: add publish job'

# --- scenario: lint-group member added ---
# Each step also reverts the previous step's addition, so every sandbox state
# renders exactly the identifier its own scenario is about.
printf 'name: a\njobs:\n  build:\n    runs-on: x\n' >"${WF_DIR}/a.yml"
printf 'lint-a:\n  - alpha\n  - beta\n' >"${LG_FILE}"
git -C "${SANDBOX}" add -A
git -C "${SANDBOX}" commit --quiet -m 'ci: add beta member'
run_scenario 'lint-group member added is reported' 0 --expect 'beta'

# --- scenario: malformed job id dropped from body ---
printf 'lint-a:\n  - alpha\n' >"${LG_FILE}"
printf 'name: a\njobs:\n  build:\n    runs-on: x\n  "Bad Job":\n    runs-on: x\n' >"${WF_DIR}/a.yml"
git -C "${SANDBOX}" add -A
git -C "${SANDBOX}" commit --quiet -m 'ci: add malformed job'
run_scenario 'malformed job id dropped from body' 0 --forbid 'Bad Job'

# --- scenario: missing workflows dir -> exit 2 ---
WF_DIR="${SANDBOX}/nope"
run_scenario 'missing workflows dir fails loudly' 2

# --- scenario: workflows dir present on disk but tracked at no ref ---
# `git ls-tree` answers with an empty list. Left unchecked, the job diff
# would render that as no jobs added and no jobs removed, and the summary
# would report PRESSURE=0 — a metric that measured nothing, printed like
# one that measured no drift. enumerate_into's breadth assertion is what
# turns that empty list into a loud failure instead.
WF_DIR="${SANDBOX}/.github/untracked-workflows"
mkdir -p "${WF_DIR}"
printf 'name: a\njobs:\n  build:\n    runs-on: x\n' >"${WF_DIR}/a.yml"
run_scenario 'workflows dir tracked at no ref fails loudly' 2 \
  --expect-err 'enumerated 0 files via git'

# @description Fresh sandbox whose backdated baseline already contains the
#              job + member that within-window commits then remove, so the
#              removal render paths fire (removals are computed against the
#              backdated boundary, not the previous commit). The removed ids
#              differ from the added ids of the other sandbox so a rendered
#              id names the render path it came from.
function make_removal_sandbox() {
  SANDBOX="$(mktemp -d)"
  WF_DIR="${SANDBOX}/.github/workflows"
  LG_FILE="${SANDBOX}/.github/lint-groups.yml"
  mkdir -p "${WF_DIR}"
  git -C "${SANDBOX}" init --quiet
  git -C "${SANDBOX}" config user.email t@t.t
  git -C "${SANDBOX}" config user.name t
  printf 'lint-a:\n  - alpha\n  - gamma\n' >"${LG_FILE}"
  printf 'name: a\njobs:\n  build:\n    runs-on: x\n  oldjob:\n    runs-on: x\n' >"${WF_DIR}/a.yml"
  git -C "${SANDBOX}" add -A
  local -r backdate_ts="$(date -d '90 days ago' '+%s') +0000"
  GIT_AUTHOR_DATE="${backdate_ts}" GIT_COMMITTER_DATE="${backdate_ts}" \
    git -C "${SANDBOX}" commit --quiet -m baseline
  # Within-window commits remove the oldjob job and the gamma member.
  printf 'name: a\njobs:\n  build:\n    runs-on: x\n' >"${WF_DIR}/a.yml"
  git -C "${SANDBOX}" add -A
  git -C "${SANDBOX}" commit --quiet -m 'ci: remove oldjob job'
  printf 'lint-a:\n  - alpha\n' >"${LG_FILE}"
  git -C "${SANDBOX}" add -A
  git -C "${SANDBOX}" commit --quiet -m 'ci: remove gamma member'
}

# --- scenario: job + member removed inside window ---
# One report carries both removal sections and both removed identifiers, so
# one invocation asserts each heading and the id rendered beneath it.
make_removal_sandbox
cd "${SANDBOX}"
run_scenario 'removed job and member are reported' 0 \
  --expect 'Jobs removed:' --expect 'oldjob' \
  --expect 'Lint-group members removed:' --expect 'gamma'

cd "${REPO_ROOT}"

harness_assert_verify || failures=$((failures + 1))

if ((failures)); then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
