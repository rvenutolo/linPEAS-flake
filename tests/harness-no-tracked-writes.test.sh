#!/usr/bin/env bash
# @subject scripts/lib/scratch-tree.sh
# tests/harness-no-tracked-writes.test.sh — proves the harnesses that
# exercise a generator or flip a fixture's mode leave the checkout they were
# started from untouched.
#
# Two groups of scenarios:
#   - `scratch-tree-*`: `reexec_in_scratch_tree` against a small throwaway
#     repository and a probe harness written at run time. They require that
#     the probe runs in a copy, that the source is not written, that an
#     uncommitted edit is visible in the copy, that the child's exit status
#     is the parent's, that an exported `GIT_DIR` does not point the copy
#     back at the source, and that the copy is removed on success and on
#     failure.
#   - `no-writes-*`: every `tests/refresh-*.test.sh` harness and
#     `tests/check-doc-anchors.test.sh`, each run from a fresh copy of the
#     tree with the (size, mode, ctime) of every file outside `.git`
#     recorded before and after. A write, a chmod, a rename or a restored
#     backup all move the ctime, so a run that rewrote a doc and put it back
#     is a finding as much as one that left it drifted.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "${REPO_ROOT}/scripts/lib/enumerate.sh"
# shellcheck source=scripts/lib/scratch-tree.sh
source "${REPO_ROOT}/scripts/lib/scratch-tree.sh"

failures=0
recorded_scenario=
work="$(mktemp --directory)"
trap 'rm --recursive --force -- "${work}"' EXIT

function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# @description Write the (path, ctime, size, mode) of every file under a
# tree, outside `.git`, one record per line, sorted.
# @arg $1 tree  @arg $2 output file
function snapshot() {
  local -a records=()
  enumerate_into records 'snapshot of the copy' \
    find "$1" -path "$1/.git" -prune -o -type f -printf '%p\t%C@\t%s\t%m\0'
  printf '%s\n' "${records[@]}" | LC_ALL=C sort >"$2"
}

# ---------------------------------------------------------------------------
# scratch-tree-*: the re-exec helper
# ---------------------------------------------------------------------------

readonly PROBE_REPO="${work}/probe-repo"
mkdir --parents -- "${PROBE_REPO}/scripts/lib" "${PROBE_REPO}/tests"
cp -- "${REPO_ROOT}"/scripts/lib/{scratch-tree,enumerate,repo,temp}.sh "${PROBE_REPO}/scripts/lib/"
printf 'original\n' >"${PROBE_REPO}/tracked.txt"
printf 'doomed\n' >"${PROBE_REPO}/gone.txt"
# The probe records where it ran, what it saw, and then overwrites a tracked
# file the way a generator would.
cat >"${PROBE_REPO}/tests/probe.test.sh" <<'PROBE'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
source "${REPO_ROOT}/scripts/lib/scratch-tree.sh"
reexec_in_scratch_tree "$@"
printf 'root=%s\n' "${REPO_ROOT}" >>"${PROBE_OUT}"
printf 'saw=%s\n' "$(cat tracked.txt)" >>"${PROBE_OUT}"
if [[ -e gone.txt ]]; then printf 'gone-present\n' >>"${PROBE_OUT}"; fi
printf 'args=%s,%s\n' "$1" "$2" >>"${PROBE_OUT}"
printf 'overwritten\n' >tracked.txt
if [[ -n ${PROBE_LOCK:-} ]]; then
  mkdir locked
  touch locked/file
  chmod 500 locked
fi
exit "${PROBE_EXIT:-0}"
PROBE
chmod +x -- "${PROBE_REPO}/tests/probe.test.sh"
function probe_git() {
  env --unset=GIT_DIR --unset=GIT_WORK_TREE --unset=GIT_INDEX_FILE \
    git -C "${PROBE_REPO}" -c user.name=probe -c user.email=probe@invalid \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
probe_git init --quiet
probe_git add --all
probe_git commit --quiet --no-verify --message probe

# @description Run the probe harness from the probe repository and write a
# report whose every line starts with the scenario name, so an asserted
# line can hold in one scenario only.
# @arg $1 scenario name  @arg $2.. extra `env` assignments for the run
# Prints the report path.
function run_probe() {
  local -r name="$1"
  shift
  local -r out="${work}/${name}.probe-out" tmp="${work}/${name}.tmp" \
    report="${work}/${name}.report"
  mkdir --parents -- "${tmp}"
  : >"${out}"
  local rc=0
  (
    cd -- "${PROBE_REPO}"
    env --unset=SCRATCH_TREE_ACTIVE "TMPDIR=${tmp}" "PROBE_OUT=${out}" "$@" \
      bash tests/probe.test.sh one two >/dev/null 2>"${work}/${name}.err"
  ) || rc=$?
  local -a left=()
  LINT_ALLOW_EMPTY_SCAN=1 enumerate_into left 'leftover scratch dirs' \
    find "${tmp}" -mindepth 1 -print0
  local source_now ran_in_source=no
  source_now="$(cat -- "${PROBE_REPO}/tracked.txt")"
  if grep --quiet --fixed-strings --line-regexp -- "root=${PROBE_REPO}" "${out}"; then
    ran_in_source=yes
  fi
  local cleanup_warning=no
  if grep --quiet --fixed-strings -- 'could not remove the scratch copy' "${work}/${name}.err"; then
    cleanup_warning=yes
  fi
  {
    printf 'harness-assert-outcome: exit=%d\n' "${rc}"
    printf '%s: cleanup warning printed: %s\n' "${name}" "${cleanup_warning}"
    printf '%s: exit status %d\n' "${name}" "${rc}"
    printf '%s: ran in the source tree: %s\n' "${name}" "${ran_in_source}"
    printf '%s: source tracked.txt after the run: %s\n' "${name}" "${source_now}"
    printf '%s: scratch dirs left behind: %d\n' "${name}" "${#left[@]}"
    sed "s/^/${name}: probe saw /" "${out}"
  } >"${report}"
  printf '%s\n' "${report}"
}

# @description Assert a scenario's report holds a line and record the line
# for the discrimination gate. The first call for a scenario opens its
# record; later calls attach to it.
# @arg $1 scenario  @arg $2 report  @arg $3 the line without its scenario prefix
function expect_line() {
  local -r want="$1: $3"
  if grep --quiet --fixed-strings --line-regexp -- "${want}" "$2"; then
    pass "${want}"
  else
    fail "expected the line '${want}'"
    cat -- "$2" >&2
  fi
  if [[ ${recorded_scenario} == "$1" ]]; then
    harness_assert_also "${want}"
  else
    harness_assert_record "$1" "${want}" "$2"
    recorded_scenario="$1"
  fi
}

report="$(run_probe scratch-tree-redirects-writes)"
expect_line scratch-tree-redirects-writes "${report}" 'ran in the source tree: no'
expect_line scratch-tree-redirects-writes "${report}" 'source tracked.txt after the run: original'

report="$(run_probe scratch-tree-passes-arguments)"
expect_line scratch-tree-passes-arguments "${report}" 'probe saw args=one,two'

report="$(run_probe scratch-tree-propagates-status PROBE_EXIT=7)"
expect_line scratch-tree-propagates-status "${report}" 'exit status 7'

report="$(run_probe scratch-tree-removes-copy-on-failure PROBE_EXIT=7)"
expect_line scratch-tree-removes-copy-on-failure "${report}" 'scratch dirs left behind: 0'

report="$(run_probe scratch-tree-ignores-exported-git-dir "GIT_DIR=${PROBE_REPO}/.git" "GIT_WORK_TREE=${PROBE_REPO}")"
expect_line scratch-tree-ignores-exported-git-dir "${report}" 'ran in the source tree: no'
expect_line scratch-tree-ignores-exported-git-dir "${report}" 'source tracked.txt after the run: original'

report="$(run_probe scratch-tree-keeps-verdict-when-cleanup-fails PROBE_LOCK=1)"
expect_line scratch-tree-keeps-verdict-when-cleanup-fails "${report}" 'exit status 0'
expect_line scratch-tree-keeps-verdict-when-cleanup-fails "${report}" 'cleanup warning printed: yes'
chmod --recursive u+w -- "${work}/scratch-tree-keeps-verdict-when-cleanup-fails.tmp"

printf 'edited\n' >"${PROBE_REPO}/tracked.txt"
rm -- "${PROBE_REPO}/gone.txt"
report="$(run_probe scratch-tree-carries-uncommitted-state)"
expect_line scratch-tree-carries-uncommitted-state "${report}" 'probe saw saw=edited'
if grep --quiet --fixed-strings -- 'gone-present' "${report}"; then
  fail 'scratch-tree-carries-uncommitted-state — a file deleted in the source is present in the copy'
else
  pass 'scratch-tree-carries-uncommitted-state — a deleted tracked file stays out of the copy'
fi

# ---------------------------------------------------------------------------
# no-writes-*: the harnesses that used to write tracked files
# ---------------------------------------------------------------------------

declare -a roster=()
glob_into roster 'refresh harnesses' "${REPO_ROOT}/tests/refresh-*.test.sh"
roster+=("${REPO_ROOT}/tests/check-doc-anchors.test.sh")

for harness in "${roster[@]}"; do
  name="no-writes-${harness##*/}"
  name="${name%.test.sh}"
  tree="${work}/${name}/tree"
  mkdir --parents -- "${tree}" "${work}/${name}.tmp"
  stage_scratch_tree "${REPO_ROOT}" "${tree}"
  snapshot "${tree}" "${work}/${name}.before"
  rc=0
  (
    cd -- "${tree}"
    env --unset=SCRATCH_TREE_ACTIVE --unset=BASH_ENV \
      "TMPDIR=${work}/${name}.tmp" \
      timeout 20m bash "tests/${harness##*/}" </dev/null \
      >"${work}/${name}.out" 2>"${work}/${name}.err"
  ) || rc=$?
  snapshot "${tree}" "${work}/${name}.after"
  changed="$(diff --unified=0 "${work}/${name}.before" "${work}/${name}.after" |
    sed --quiet 's/^[-+]\([^-+@].*\)$/\1/p' | cut --fields=1 | sort --unique || true)"
  {
    printf 'harness-assert-outcome: exit=%d\n' "${rc}"
    printf 'harness: %s\n' "${harness##*/}"
    printf 'tracked files changed: %s\n' "${changed:-none}"
  } >"${work}/${name}.report"
  if [[ ${rc} -ne 0 ]]; then
    fail "${name} — the harness exited ${rc}"
    cat -- "${work}/${name}.out" "${work}/${name}.err" >&2
  elif [[ -n ${changed} ]]; then
    fail "${name} — the run changed files in the tree it was started from:"
    printf '%s\n' "${changed}" >&2
  else
    pass "${name} — no file in the starting tree changed"
  fi
  harness_assert_record "${name}" 'tracked files changed: none' "${work}/${name}.report"
done

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -gt 0 ]]; then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
