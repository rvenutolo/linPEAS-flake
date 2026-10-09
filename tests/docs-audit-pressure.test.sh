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
# shellcheck source=scripts/lib/locale-gap.sh
source "${REPO_ROOT}/scripts/lib/locale-gap.sh"
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
#         `--expect-err <substring>` (must appear in stderr),
#         `--forbid <substring>` (must not appear in stdout) and
#         `--forbid-err <substring>` (must not appear in stderr), each
#         repeatable
function run_scenario() {
  local -r name="$1"
  local -r expected_exit="$2"
  shift 2

  local -a expect_subs=() expect_err_subs=() forbid_subs=() forbid_err_subs=()
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
    --forbid-err)
      forbid_err_subs+=("$2")
      shift 2
      ;;
    *)
      printf 'FAIL: %s — run_scenario got unknown argument %q\n' "${name}" "$1" >&2
      exit 1
      ;;
    esac
  done

  local out_file err_file outcome_file run_tmp leftover actual_exit=0
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  outcome_file="$(mktemp)"
  # The script's own temp files go to a directory of this run's, so that
  # one it leaves behind can be seen.
  run_tmp="$(mktemp --directory)"

  # SCRIPT_PATH, when a scenario sets it, is the PATH of the script alone:
  # a stub of a tool this function also runs must not answer its calls.
  PATH="${SCRIPT_PATH:-${PATH}}" TMPDIR="${run_tmp}" DOCS_AUDIT_STATE_OVERRIDE="${STATE_FILE}" \
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

  leftover="$(ls --almost-all -- "${run_tmp}")"
  rm --recursive --force -- "${run_tmp}"
  if [[ -n ${leftover} ]]; then
    printf 'FAIL: %s — the script left a temp file behind (%s)\n' "${name}" "${leftover}" >&2
    failures=$((failures + 1))
    return
  fi
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
  for sub in "${forbid_err_subs[@]}"; do
    if grep --fixed-strings --quiet -- "${sub}" "${err_file}"; then
      printf 'FAIL: %s — stderr must not contain %q\n' "${name}" "${sub}" >&2
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

# @description Record a sandbox commit as that sandbox's audit point.
#              The marker sits outside the pressure pathspec
#              (WORKFLOWS_DIR, scripts, LINT_GROUPS), so writing it never
#              contributes to the count it is the base for.
# @arg $1 ref to record (default HEAD)
function mark_audit_point() {
  local -r ref="${1:-HEAD}"
  local sha
  sha="$(git -C "${SANDBOX}" rev-parse "${ref}")"
  printf 'LAST_AUDIT_SHA=%s\n' "${sha}" >"${STATE_FILE}"
}

# @description Create a scratch git repo; export WF_DIR / LG_FILE /
#              STATE_FILE / SANDBOX, with the baseline commit recorded as
#              the audit point.
function make_sandbox() {
  SANDBOX="$(mktemp -d)"
  WF_DIR="${SANDBOX}/.github/workflows"
  LG_FILE="${SANDBOX}/.github/lint-groups.yml"
  STATE_FILE="${SANDBOX}/.github/docs-audit-state"
  mkdir -p "${WF_DIR}"
  git -C "${SANDBOX}" init --quiet
  git -C "${SANDBOX}" config user.email t@t.t
  git -C "${SANDBOX}" config user.name t
  printf 'lint-a:\n  - alpha\n' >"${LG_FILE}"
  printf 'name: a\njobs:\n  build:\n    runs-on: x\n' >"${WF_DIR}/a.yml"
  git -C "${SANDBOX}" add -A
  git -C "${SANDBOX}" commit --quiet -m baseline
  mark_audit_point
}

# --- scenario: nothing since the audit point -> pressure 0 ---
make_sandbox
cd "${SANDBOX}"
run_scenario 'no commits since the audit point reports zero pressure' 0 --expect 'PRESSURE=0'

# --- scenario: job added after the audit point ---
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

# --- scenario: lint-group members read by kind ---
# A group written as a list carrying a tag of its own still lists its
# members; a group written as a map lists none, so its values are not
# counted as members.
printf 'lint-a: !x [alpha, epsilon]\nlint-b: {delta: 1}\n' >"${LG_FILE}"
git -C "${SANDBOX}" add -A
git -C "${SANDBOX}" commit --quiet -m 'ci: tag a group and add a map group'
BT=$'\x60'
run_scenario 'a tagged member list is read and a map group lists no member' 0 \
  --expect "- ${BT}epsilon${BT}" --forbid 'delta' --forbid "${BT}1${BT}"
printf 'lint-a:\n  - alpha\n  - beta\n' >"${LG_FILE}"

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
# turns that empty list into a loud failure instead. The caller passes a
# label carrying the workflows dir and the ref it queried, so an operator
# reading the diagnostic can tell which directory and which ref came back
# empty without re-deriving them from the invocation.
WF_DIR="${SANDBOX}/.github/untracked-workflows"
mkdir -p "${WF_DIR}"
printf 'name: a\njobs:\n  build:\n    runs-on: x\n' >"${WF_DIR}/a.yml"
run_scenario 'workflows dir tracked at no ref fails loudly' 2 \
  --expect-err "enumerated 0 files via git ls-tree ${WF_DIR} at"

# --- scenario: workflows dir tracked at ref but holds no YAML file ---
# `git ls-tree` returns a non-empty list (README.txt), so
# enumerate_into's own raw-breadth guard is satisfied and does not fire.
# The YAML-extension filter downstream then narrows that list to zero,
# and its own retained breadth check is what catches this branch —
# distinct from the raw-empty case above, which enumerate_into itself
# catches before the filter ever runs.
function make_non_yaml_workflow_sandbox() {
  SANDBOX="$(mktemp --directory)"
  WF_DIR="${SANDBOX}/.github/workflows"
  LG_FILE="${SANDBOX}/.github/lint-groups.yml"
  STATE_FILE="${SANDBOX}/.github/docs-audit-state"
  mkdir --parents "${WF_DIR}"
  git -C "${SANDBOX}" init --quiet
  git -C "${SANDBOX}" config user.email t@t.t
  git -C "${SANDBOX}" config user.name t
  printf 'lint-a:\n  - alpha\n' >"${LG_FILE}"
  printf 'not a workflow\n' >"${WF_DIR}/README.txt"
  git -C "${SANDBOX}" add --all
  git -C "${SANDBOX}" commit --quiet -m baseline
  mark_audit_point
}
make_non_yaml_workflow_sandbox
cd "${SANDBOX}"
run_scenario 'workflows dir tracked with no yaml file fails loudly' 2 \
  --expect-err "enumerated 0 workflow file(s) under ${WF_DIR} at"

# @description Fresh sandbox whose audit-point baseline already contains
#              the job + member that later commits then remove, so the
#              removal render paths fire (removals are computed against the
#              recorded audit point, not the previous commit). The removed
#              ids differ from the added ids of the other sandbox so a
#              rendered id names the render path it came from.
function make_removal_sandbox() {
  SANDBOX="$(mktemp -d)"
  WF_DIR="${SANDBOX}/.github/workflows"
  LG_FILE="${SANDBOX}/.github/lint-groups.yml"
  STATE_FILE="${SANDBOX}/.github/docs-audit-state"
  mkdir -p "${WF_DIR}"
  git -C "${SANDBOX}" init --quiet
  git -C "${SANDBOX}" config user.email t@t.t
  git -C "${SANDBOX}" config user.name t
  printf 'lint-a:\n  - alpha\n  - gamma\n' >"${LG_FILE}"
  printf 'name: a\njobs:\n  build:\n    runs-on: x\n  oldjob:\n    runs-on: x\n' >"${WF_DIR}/a.yml"
  git -C "${SANDBOX}" add -A
  git -C "${SANDBOX}" commit --quiet -m baseline
  mark_audit_point
  # Commits after the audit point remove the oldjob job and gamma member.
  printf 'name: a\njobs:\n  build:\n    runs-on: x\n' >"${WF_DIR}/a.yml"
  git -C "${SANDBOX}" add -A
  git -C "${SANDBOX}" commit --quiet -m 'ci: remove oldjob job'
  printf 'lint-a:\n  - alpha\n' >"${LG_FILE}"
  git -C "${SANDBOX}" add -A
  git -C "${SANDBOX}" commit --quiet -m 'ci: remove gamma member'
}

# --- scenario: job + member removed after the audit point ---
# One report carries both removal sections and both removed identifiers, so
# one invocation asserts each heading and the id rendered beneath it.
make_removal_sandbox
cd "${SANDBOX}"
run_scenario 'removed job and member are reported' 0 \
  --expect 'Jobs removed:' --expect 'oldjob' \
  --expect 'Lint-group members removed:' --expect 'gamma'

# @description Make a directory holding a `yq` that exits with a given
# status for one job-id read and hands every other call to the real `yq`,
# and point STUB_DIR at it. The job-id read is the one whose expression
# holds `| keys`, which the lint-group read does not; it takes its
# workflow as a file, its last argument, under one temp name for every
# workflow at a ref, so the read to fail is picked by text that file
# holds.
# `-` fails every job-id read, of which the first is the audit point's.
# A scenario puts the directory first on PATH for its own run only.
# @arg $1 exit status for the failing read
# @arg $2 text the failing read's input holds, or `-`
function yq_stub() {
  local real_yq
  real_yq="$(command -v yq)"
  STUB_DIR="$(mktemp --directory)"
  # shellcheck disable=SC2016 # the stub's own expansions, written literally
  printf '#!/usr/bin/env bash\ncase "$*" in *%q*)\n  if [[ %q == - ]]; then exit %d; fi\n  if grep --quiet --fixed-strings -- %q "${!#}"; then exit %d; fi ;;\nesac\nexec %q "$@"\n' \
    '| keys' "$2" "$1" "$2" "$1" "${real_yq}" >"${STUB_DIR}/yq"
  chmod +x -- "${STUB_DIR}/yq"
}

# @description Make a directory holding a `git` that exits with a given
# status for every call whose arguments hold a given string and hands any
# other call to the real `git`, and point STUB_DIR at it.
# @arg $1 argument text that marks the failing call
# @arg $2 exit status for that call
function git_stub() {
  local real_git
  real_git="$(command -v git)"
  STUB_DIR="$(mktemp --directory)"
  printf '#!/usr/bin/env bash\ncase "$*" in *%q*) exit %d ;; esac\nexec %q "$@"\n' \
    "$1" "$2" "${real_git}" >"${STUB_DIR}/git"
  chmod +x -- "${STUB_DIR}/git"
}

# @description Make a directory holding a `mktemp` that fails on one of
# its calls, counted from 1, and hands every other call to the real
# `mktemp`, and point STUB_DIR at it.
# @arg $1 the call to fail
function mktemp_stub() {
  local real_mktemp
  real_mktemp="$(command -v mktemp)"
  STUB_DIR="$(mktemp --directory)"
  # shellcheck disable=SC2016 # the stub's own expansions, written literally
  printf '#!/usr/bin/env bash\ncount=%q\nn=$(($(cat -- "${count}" 2>/dev/null || printf 0) + 1))\nprintf "%%d" "${n}" >"${count}"\nif ((n == %d)); then exit 1; fi\nexec %q "$@"\n' \
    "${STUB_DIR}/count" "$1" "${real_mktemp}" >"${STUB_DIR}/mktemp"
  chmod +x -- "${STUB_DIR}/mktemp"
}

# --- scenarios: a workflow's job ids cannot be read ---
# A read that fails drops no workflow from the set: the run stops, naming
# the workflow, the ref, the tool and its status. Left to pass, the jobs
# of a workflow unread at the audit point are reported as added since,
# and those of one unread at HEAD as removed.
make_sandbox
cd "${SANDBOX}"
base_sha="$(git -C "${SANDBOX}" rev-parse HEAD)"
printf 'name: a\njobs:\n  build:\n    runs-on: x\n  rollout:\n    runs-on: x\n' >"${WF_DIR}/a.yml"
git -C "${SANDBOX}" add --all
git -C "${SANDBOX}" commit --quiet -m 'ci: add rollout job'

yq_stub 7 -
PATH="${STUB_DIR}:${PATH}" run_scenario 'failed job-id read at the audit point stops the run' 2 \
  --expect-err "cannot read job ids from .github/workflows/a.yml at ${base_sha}: yq exited 7" \
  --forbid 'PRESSURE='
rm --recursive --force -- "${STUB_DIR}"

# `rollout` is in the workflow at HEAD only, so only that read fails.
yq_stub 9 rollout
PATH="${STUB_DIR}:${PATH}" run_scenario 'failed job-id read at HEAD stops the run' 2 \
  --expect-err 'cannot read job ids from .github/workflows/a.yml at HEAD: yq exited 9' \
  --forbid 'PRESSURE='
rm --recursive --force -- "${STUB_DIR}"

# The second temp file the script asks for is the one the audit point's
# workflows are written to. Without it nothing was read, and the line
# names the temp file, not a git read that never ran.
mktemp_stub 2
SCRIPT_PATH="${STUB_DIR}:${PATH}" run_scenario 'no temp file for the workflows stops the run' 2 \
  --expect-err 'cannot create a temp file' \
  --forbid-err 'git show exited' --forbid 'PRESSURE='
rm --recursive --force -- "${STUB_DIR}"

git_stub "show ${base_sha}:.github/workflows/a.yml" 5
PATH="${STUB_DIR}:${PATH}" run_scenario 'workflow git cannot show stops the run' 2 \
  --expect-err "cannot read .github/workflows/a.yml at ${base_sha}: git show exited 5" \
  --forbid 'PRESSURE='
rm --recursive --force -- "${STUB_DIR}"

# A workflow with no `jobs:` and one with an empty `jobs:` hold no id and
# are not unreadable: the job added beside them is still reported.
printf 'name: b\non: push\n' >"${WF_DIR}/b.yml"
printf 'name: c\njobs: {}\n' >"${WF_DIR}/c.yml"
git -C "${SANDBOX}" add --all
git -C "${SANDBOX}" commit --quiet -m 'ci: add jobless workflows'
run_scenario 'workflows without jobs read as no ids' 0 \
  --expect 'rollout'

# The job set is every document's: a file whose first document holds no
# `jobs:` still contributes the jobs of its second. A `jobs:` written as
# an alias stands for the map it names. The job the scenario above
# reports is taken back out, so each report names its own jobs.
printf 'name: a\njobs:\n  build:\n    runs-on: x\n' >"${WF_DIR}/a.yml"
printf 'name: d\n---\njobs:\n  canary:\n    runs-on: x\n' >"${WF_DIR}/d.yml"
printf 'x: &j\n  mirror:\n    runs-on: x\njobs: *j\n' >"${WF_DIR}/e.yml"
# Only `jobs:` is resolved: a merge key `yq` cannot resolve elsewhere in
# a workflow leaves its job ids readable.
printf 'c: &c [x]\nenv:\n  <<: *c\njobs:\n  sentinel:\n    runs-on: x\n' >"${WF_DIR}/g.yml"
git -C "${SANDBOX}" add --all
git -C "${SANDBOX}" commit --quiet -m 'ci: add a two-document and an aliased workflow'
run_scenario 'later documents and aliased jobs are counted' 0 \
  --expect 'canary' --expect 'mirror' --expect 'sentinel'

# A job id written as an alias inside an aliased `jobs:` map is the name it
# stands for, also through a merge list. The jobs the scenario above
# reports are taken back out, so each report names its own jobs.
git -C "${SANDBOX}" rm --quiet -- "${WF_DIR}/d.yml" "${WF_DIR}/e.yml" "${WF_DIR}/g.yml"
printf 'name: &k nested-key-job\nx: &j\n  *k :\n    runs-on: x\njobs: *j\n' >"${WF_DIR}/h.yml"
printf 'name: &k merged-key-job\na: &a\n  *k :\n    runs-on: x\nb: &b\n  <<: [*a]\njobs: *b\n' >"${WF_DIR}/i.yml"
git -C "${SANDBOX}" add --all
git -C "${SANDBOX}" commit --quiet -m 'ci: add workflows with aliased job keys'
run_scenario 'aliased job keys inside an aliased jobs map are counted' 0 \
  --expect 'nested-key-job' --expect 'merged-key-job' --forbid '*k'

# A merge chain three levels deep resolves to the keys it brings in, not to
# the merge key: the read passes the flag that merges by the YAML
# specification, as the other `jobs:` reads do. The jobs of the scenario
# above are taken back out.
git -C "${SANDBOX}" rm --quiet -- "${WF_DIR}/h.yml" "${WF_DIR}/i.yml"
printf 'm0: &m0\n  chain-base-job:\n    runs-on: x\nm1: &m1\n  <<: *m0\n  chain-own-job:\n    runs-on: x\nm2: &m2\n  <<: *m1\njobs: *m2\n' >"${WF_DIR}/j.yml"
git -C "${SANDBOX}" add --all
git -C "${SANDBOX}" commit --quiet -m 'ci: add a workflow merging a chain of maps'
run_scenario 'a merge chain under jobs is resolved to its keys' 0 \
  --expect 'chain-base-job' --expect 'chain-own-job' --forbid '<<'

# A workflow holding a NUL byte is one `yq` cannot read. The bytes git
# prints must reach `yq` as they are: a shell variable drops the NUL and
# hands `yq` a different, readable file.
printf 'name: f\njobs:\n  ghost:\n    runs-on: x\n# \0\n' >"${WF_DIR}/f.yml"
git -C "${SANDBOX}" add --all
git -C "${SANDBOX}" commit --quiet -m 'ci: add a workflow holding a NUL'
run_scenario 'workflow holding a NUL byte stops the run' 2 \
  --expect-err 'cannot read job ids from .github/workflows/f.yml at HEAD: yq exited 1' \
  --forbid 'ghost'
git -C "${SANDBOX}" rm --quiet -- "${WF_DIR}/f.yml"
git -C "${SANDBOX}" commit --quiet -m 'ci: drop the workflow holding a NUL'

# A workflow that does not parse at HEAD, committed at run time so no
# unparsable file sits in the tree for the formatters to refuse.
printf 'name: a\njobs: [build\n' >"${WF_DIR}/a.yml"
git -C "${SANDBOX}" add --all
git -C "${SANDBOX}" commit --quiet -m 'ci: break a workflow'
run_scenario 'unparsable workflow at HEAD stops the run' 2 \
  --expect-err 'cannot read job ids from .github/workflows/a.yml at HEAD: yq exited 1' \
  --forbid 'Jobs removed:'

cd "${REPO_ROOT}"

# --- scenario: an audit point holding a non-ASCII letter -> exit 2 ---
# Under en_US.UTF-8 a bash `[0-9a-f]` range also matches non-ASCII
# letters, so 39 hex digits and an `é` would pass the shape check and
# reach git as a revision. The shape check is what must refuse it.
require_locale_gap en_US.UTF-8 || exit 1
make_sandbox
cd "${SANDBOX}"
audit_sha="$(git -C "${SANDBOX}" rev-parse HEAD)"
printf 'LAST_AUDIT_SHA=%sé\n' "${audit_sha:0:39}" >"${STATE_FILE}"
LC_ALL=en_US.UTF-8 run_scenario 'audit point with a non-ASCII letter is refused under en_US.UTF-8' 2 \
  --expect-err "${STATE_FILE}: no LAST_AUDIT_SHA=<40-hex> line" \
  --forbid-err 'is not a commit in this history'
STATE_FILE="${SANDBOX}/.github/state-before"
printf 'LAST_AUDIT_SHA=é%s\n' "${audit_sha}" >"${STATE_FILE}"
LC_ALL=en_US.UTF-8 run_scenario 'non-ASCII letter before the audit point is refused under en_US.UTF-8' 2 \
  --expect-err "${STATE_FILE}: no LAST_AUDIT_SHA=<40-hex> line" \
  --forbid-err 'is not a commit in this history'
STATE_FILE="${SANDBOX}/.github/state-after"
printf 'LAST_AUDIT_SHA=%sé\n' "${audit_sha}" >"${STATE_FILE}"
LC_ALL=en_US.UTF-8 run_scenario 'non-ASCII letter after the audit point is refused under en_US.UTF-8' 2 \
  --expect-err "${STATE_FILE}: no LAST_AUDIT_SHA=<40-hex> line" \
  --forbid-err 'is not a commit in this history'
cd "${REPO_ROOT}"

harness_assert_verify || failures=$((failures + 1))

if ((failures)); then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
