#!/usr/bin/env bash
# @subject scripts/lib/scratch-tree.sh
# tests/harness-no-tracked-writes.test.sh — proves the harnesses that
# exercise a generator or flip a fixture's mode leave the checkout they were
# started from untouched.
#
# Three groups of scenarios:
#   - `scratch-tree-*`: `reexec_in_scratch_tree` against a small throwaway
#     repository and a probe harness written at run time. They require that
#     the probe runs in a copy and the source is not written, that an
#     uncommitted edit is visible in the copy and a deleted file is not,
#     that arguments and the child's exit status pass through, that an
#     exported `GIT_DIR`, an inherited `SCRATCH_TREE_ACTIVE`, a relative
#     `TMPDIR`, a run from a subdirectory and job control do not break the
#     re-exec, that an unreadable tracked file fails the copy, and that a
#     SIGTERM during the build or during the copy run reaches the whole
#     process group, waits for it and removes the copy.
#   - `snapshot-*`: the change detector alone, on a constructed tree: it
#     must see a new or deleted file, a same-content rewrite, a chmod
#     round trip, a retargeted symlink, a directory mode change and a new
#     empty directory, and must not see a write under `.git` or no change.
#   - `no-writes-*`: every `tests/refresh-*.test.sh` harness and
#     `tests/check-doc-anchors.test.sh`, each run from a fresh copy of the
#     tree with the (type, link target, size, mode, ctime) of every entry
#     outside `.git` recorded before and after. A write, a chmod, a
#     rename or a restored backup all move the ctime, so a run that
#     rewrote a doc and put it back is a finding as much as one that left
#     it drifted.
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

probe_cwd=''
probe_cmd=()
function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# @description Write the (path, type, link target, ctime, size, mode) of
# every entry under a tree, outside `.git`, one record per line, sorted.
# Directories and symbolic links are entries too: a retargeted link or a
# new empty directory is a change.
# @arg $1 tree  @arg $2 output file
function snapshot() {
  local -a records=()
  enumerate_into records 'snapshot of the copy' \
    find "$1" -path "$1/.git" -prune -o -printf '%p\t%y\t%l\t%C@\t%s\t%m\0'
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
printf 'secret\n' >"${PROBE_REPO}/secret.txt"
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
if [[ -n ${PROBE_SLEEP:-} ]]; then
  printf '%s\n' "$$" >"${PROBE_OUT}.pid"
  : >"${PROBE_OUT}.started"
  if [[ -n ${PROBE_GRAND:-} ]]; then
    sleep 30 &
    printf '%s\n' "$!" >"${PROBE_OUT}.gpid"
    wait $!
  elif [[ -n ${PROBE_TRAP:-} ]]; then
    trap 'sleep 1; : >"${PROBE_OUT}.cleaned"; exit 143' TERM
    sleep 3 &
    wait $!
  else
    sleep 3
  fi
fi
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
# Runs from `probe_cwd`, which defaults to the probe repository's root.
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
    cd -- "${probe_cwd}"
    env --unset=SCRATCH_TREE_ACTIVE "TMPDIR=${tmp}" "PROBE_OUT=${out}" "$@" \
      "${probe_cmd[@]}" >/dev/null 2>"${work}/${name}.err"
  ) || rc=$?
  local -a left=()
  LINT_ALLOW_EMPTY_SCAN=1 enumerate_into left 'leftover scratch dirs' \
    find "${tmp}" -mindepth 1 -print0
  local source_now ran_in_source=no reached_body=no
  if grep --quiet --extended-regexp -- '^root=' "${out}"; then
    reached_body=yes
  fi
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
    printf '%s: probe reached its body: %s\n' "${name}" "${reached_body}"
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

probe_cwd="${PROBE_REPO}"
probe_cmd=(bash "${PROBE_REPO}/tests/probe.test.sh" one two)
report="$(run_probe scratch-tree-redirects-writes)"
expect_line scratch-tree-redirects-writes "${report}" 'probe reached its body: yes'
expect_line scratch-tree-redirects-writes "${report}" 'ran in the source tree: no'
expect_line scratch-tree-redirects-writes "${report}" 'source tracked.txt after the run: original'

report="$(run_probe scratch-tree-passes-arguments)"
expect_line scratch-tree-passes-arguments "${report}" 'probe saw args=one,two'

report="$(run_probe scratch-tree-propagates-status PROBE_EXIT=7)"
expect_line scratch-tree-propagates-status "${report}" 'exit status 7'

report="$(run_probe scratch-tree-removes-copy-on-failure PROBE_EXIT=7)"
expect_line scratch-tree-removes-copy-on-failure "${report}" 'scratch dirs left behind: 0'

report="$(run_probe scratch-tree-ignores-exported-git-dir "GIT_DIR=${PROBE_REPO}/.git" "GIT_WORK_TREE=${PROBE_REPO}")"
expect_line scratch-tree-ignores-exported-git-dir "${report}" 'probe reached its body: yes'
expect_line scratch-tree-ignores-exported-git-dir "${report}" 'ran in the source tree: no'
expect_line scratch-tree-ignores-exported-git-dir "${report}" 'source tracked.txt after the run: original'

report="$(run_probe scratch-tree-keeps-verdict-when-cleanup-fails PROBE_LOCK=1)"
expect_line scratch-tree-keeps-verdict-when-cleanup-fails "${report}" 'exit status 0'
expect_line scratch-tree-keeps-verdict-when-cleanup-fails "${report}" 'cleanup warning printed: yes'
chmod --recursive u+w -- "${work}/scratch-tree-keeps-verdict-when-cleanup-fails.tmp"

probe_cwd="${PROBE_REPO}/tests"
report="$(run_probe scratch-tree-runs-from-subdirectory)"
expect_line scratch-tree-runs-from-subdirectory "${report}" 'probe reached its body: yes'
expect_line scratch-tree-runs-from-subdirectory "${report}" 'ran in the source tree: no'
probe_cwd="${PROBE_REPO}"

# @description Start the probe, send its parent SIGTERM while the copy run
# is in flight, and report what the parent left behind.
# @arg $1 scenario name  @arg $2.. extra `env` assignments for the run
function run_signal_case() {
  local -r name="$1"
  shift
  local -r tmp="${work}/${name}.tmp" out="${work}/${name}.probe-out"
  mkdir --parents -- "${tmp}"
  : >"${out}"
  (
    cd -- "${PROBE_REPO}"
    exec env --unset=SCRATCH_TREE_ACTIVE "TMPDIR=${tmp}" "PROBE_OUT=${out}" \
      PROBE_SLEEP=1 "$@" \
      bash "${PROBE_REPO}/tests/probe.test.sh" one two >/dev/null 2>&1
  ) &
  local -r pid=$!
  local _
  for _ in $(seq 1 100); do
    [[ -e ${out}.started ]] && break
    sleep 0.2
  done
  kill -TERM "${pid}"
  local rc=0
  wait "${pid}" || rc=$?
  local -a left=()
  LINT_ALLOW_EMPTY_SCAN=1 enumerate_into left 'leftover scratch dirs' \
    find "${tmp}" -mindepth 1 -print0
  local alive=no cleaned=no sub=no
  if kill -0 "$(cat -- "${out}.pid")" 2>/dev/null; then alive=yes; fi
  if [[ -e ${out}.gpid ]] && kill -0 "$(cat -- "${out}.gpid")" 2>/dev/null; then
    sub=yes
    kill -KILL "$(cat -- "${out}.gpid")" 2>/dev/null || true
  fi
  if [[ -e ${out}.cleaned ]]; then cleaned=yes; fi
  {
    printf '%s: exit status %d\n' "${name}" "${rc}"
    printf '%s: scratch dirs left behind: %d\n' "${name}" "${#left[@]}"
    printf '%s: copy run still alive after the parent exited: %s\n' "${name}" "${alive}"
    printf '%s: copy run finished its cleanup before the parent exited: %s\n' "${name}" "${cleaned}"
    printf '%s: harness subprocess still alive after the parent exited: %s\n' "${name}" "${sub}"
  } >"${work}/${name}.report"
}

# A harness stopped by SIGTERM while its copy run is in flight forwards the
# signal, removes the copy and reports the signal's status.
run_signal_case scratch-tree-removes-copy-on-signal
signal_report="${work}/scratch-tree-removes-copy-on-signal.report"
expect_line scratch-tree-removes-copy-on-signal "${signal_report}" 'exit status 143'
expect_line scratch-tree-removes-copy-on-signal "${signal_report}" 'scratch dirs left behind: 0'
expect_line scratch-tree-removes-copy-on-signal "${signal_report}" 'copy run still alive after the parent exited: no'

# The parent waits for a copy run that needs time to clean up after SIGTERM,
# so the copy is not removed under it.
run_signal_case scratch-tree-waits-for-slow-cleanup PROBE_TRAP=1
signal_report="${work}/scratch-tree-waits-for-slow-cleanup.report"
expect_line scratch-tree-waits-for-slow-cleanup "${signal_report}" 'copy run finished its cleanup before the parent exited: yes'
expect_line scratch-tree-waits-for-slow-cleanup "${signal_report}" 'scratch dirs left behind: 0'

# The signal reaches what the copy run started, not only the copy run.
run_signal_case scratch-tree-signals-the-whole-group PROBE_GRAND=1
signal_report="${work}/scratch-tree-signals-the-whole-group.report"
expect_line scratch-tree-signals-the-whole-group "${signal_report}" 'harness subprocess still alive after the parent exited: no'
expect_line scratch-tree-signals-the-whole-group "${signal_report}" 'exit status 143'

# @description Send SIGTERM while the copy is still being built. A `git` shim
# that waits half a second per call keeps the build step running long enough
# to signal it; the shim records the pid of each call.
function run_early_signal_case() {
  local -r name="$1"
  local -r tmp="${work}/${name}.tmp" out="${work}/${name}.probe-out" \
    shim="${work}/${name}.shim" pids="${work}/${name}.shim-pids"
  local real_git
  real_git="$(command -v git)"
  mkdir --parents -- "${tmp}" "${shim}"
  : >"${out}"
  : >"${pids}"
  cat >"${shim}/git" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$$" >>"${SHIM_PIDS}"
sleep 0.5
exec "${REAL_GIT}" "$@"
SHIM
  chmod +x -- "${shim}/git"
  (
    cd -- "${PROBE_REPO}"
    exec env --unset=SCRATCH_TREE_ACTIVE "TMPDIR=${tmp}" "PROBE_OUT=${out}" \
      "PATH=${shim}:${PATH}" "SHIM_PIDS=${pids}" "REAL_GIT=${real_git}" \
      PROBE_SLEEP=1 \
      bash "${PROBE_REPO}/tests/probe.test.sh" one two >/dev/null 2>&1
  ) &
  local -r pid=$!
  local _ staged=no
  local -a present=()
  for _ in $(seq 1 200); do
    LINT_ALLOW_EMPTY_SCAN=1 enumerate_into present 'scratch dirs under way' \
      find "${tmp}" -mindepth 1 -maxdepth 1 -print0
    if ((${#present[@]} > 0)); then
      staged=yes
      break
    fi
    sleep 0.05
  done
  kill -TERM "${pid}"
  local rc=0
  wait "${pid}" || rc=$?
  local -a left=()
  LINT_ALLOW_EMPTY_SCAN=1 enumerate_into left 'leftover scratch dirs' \
    find "${tmp}" -mindepth 1 -print0
  local running=no shim_pid
  while IFS= read -r shim_pid; do
    if [[ -n ${shim_pid} ]] && kill -0 "${shim_pid}" 2>/dev/null; then running=yes; fi
  done <"${pids}"
  local reached=no
  if [[ -e ${out}.started ]]; then reached=yes; fi
  {
    printf '%s: copy directory existed when the signal was sent: %s\n' "${name}" "${staged}"
    printf '%s: exit status %d\n' "${name}" "${rc}"
    printf '%s: scratch dirs left behind: %d\n' "${name}" "${#left[@]}"
    printf '%s: staging subprocess still running after the parent exited: %s\n' "${name}" "${running}"
    printf '%s: probe body ran: %s\n' "${name}" "${reached}"
  } >"${work}/${name}.report"
}

run_early_signal_case scratch-tree-signal-during-staging
signal_report="${work}/scratch-tree-signal-during-staging.report"
expect_line scratch-tree-signal-during-staging "${signal_report}" 'copy directory existed when the signal was sent: yes'
expect_line scratch-tree-signal-during-staging "${signal_report}" 'staging subprocess still running after the parent exited: no'
expect_line scratch-tree-signal-during-staging "${signal_report}" 'scratch dirs left behind: 0'
expect_line scratch-tree-signal-during-staging "${signal_report}" 'probe body ran: no'

# Under job control the copy run's launcher would fork and exit at once. A
# pseudo-terminal from `script` lets `bash -m` really enable it.
if command -v script >/dev/null 2>&1; then
  probe_cmd=(script -qec "bash -m '${PROBE_REPO}/tests/probe.test.sh' one two" /dev/null)
  report="$(run_probe scratch-tree-works-under-job-control)"
  expect_line scratch-tree-works-under-job-control "${report}" 'probe reached its body: yes'
  expect_line scratch-tree-works-under-job-control "${report}" 'exit status 0'
  probe_cmd=(bash "${PROBE_REPO}/tests/probe.test.sh" one two)
else
  pass 'scratch-tree-works-under-job-control — skipped, script is not on PATH'
fi

# The helper's work-tree lookup is a could-not-run: a script outside any work
# tree that calls it exits 2 naming the missing tree.
outside="${work}/outside"
mkdir --parents -- "${outside}"
cat >"${outside}/caller.sh" <<'CALLER'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
source "${LIB_DIR}/scratch-tree.sh"
reexec_in_scratch_tree
CALLER
outside_rc=0
(
  cd -- "${outside}"
  env "GIT_CEILING_DIRECTORIES=${work}" "LIB_DIR=${PROBE_REPO}/scripts/lib" \
    bash caller.sh </dev/null >/dev/null 2>"${work}/outside.err"
) || outside_rc=$?
{
  printf 'scratch-tree-outside-a-work-tree: exit status %d\n' "${outside_rc}"
  if grep --quiet --fixed-strings -- 'caller.sh: cannot resolve the git work tree' "${work}/outside.err"; then
    printf 'scratch-tree-outside-a-work-tree: diagnostic names the missing work tree: yes\n'
  else
    printf 'scratch-tree-outside-a-work-tree: diagnostic names the missing work tree: no\n'
  fi
} >"${work}/outside.report"
expect_line scratch-tree-outside-a-work-tree "${work}/outside.report" 'exit status 2'
expect_line scratch-tree-outside-a-work-tree "${work}/outside.report" 'diagnostic names the missing work tree: yes'

mkdir --parents -- "${PROBE_REPO}/reltmp"
report="$(run_probe scratch-tree-accepts-relative-tmpdir TMPDIR=reltmp)"
expect_line scratch-tree-accepts-relative-tmpdir "${report}" 'exit status 0'
expect_line scratch-tree-accepts-relative-tmpdir "${report}" 'probe reached its body: yes'

report="$(run_probe scratch-tree-ignores-inherited-marker SCRATCH_TREE_ACTIVE=/nonexistent)"
expect_line scratch-tree-ignores-inherited-marker "${report}" 'probe reached its body: yes'
expect_line scratch-tree-ignores-inherited-marker "${report}" 'ran in the source tree: no'

chmod 000 -- "${PROBE_REPO}/secret.txt"
if [[ -r ${PROBE_REPO}/secret.txt ]]; then
  pass 'scratch-tree-fails-on-unreadable-file — skipped, the file is readable at mode 000 (running as root)'
else
  report="$(run_probe scratch-tree-fails-on-unreadable-file)"
  expect_line scratch-tree-fails-on-unreadable-file "${report}" 'exit status 2'
  expect_line scratch-tree-fails-on-unreadable-file "${report}" 'probe reached its body: no'
fi
chmod 644 -- "${PROBE_REPO}/secret.txt"

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
# snapshot-*: the change detector
# ---------------------------------------------------------------------------

# @description Build a small tree, snapshot it, apply one change, snapshot
# again, and assert whether the two snapshots differ.
# @arg $1 scenario name  @arg $2 expected: yes (differ) or no (equal)
# @arg $3 change: a function name from `apply_change`
function snapshot_case() {
  local -r name="$1" want="$2" change="$3"
  local -r tree="${work}/${name}/tree"
  mkdir --parents -- "${tree}/d" "${tree}/.git"
  printf 'a\n' >"${tree}/a"
  ln -s a "${tree}/link"
  snapshot "${tree}" "${work}/${name}.before"
  apply_change "${change}" "${tree}"
  snapshot "${tree}" "${work}/${name}.after"
  local differ=no
  cmp --silent -- "${work}/${name}.before" "${work}/${name}.after" || differ=yes
  printf '%s: snapshot changed: %s\n' "${name}" "${differ}" >"${work}/${name}.report"
  expect_line "${name}" "${work}/${name}.report" "snapshot changed: ${want}"
}

# @description Apply one named change to a snapshot tree.
function apply_change() {
  local -r tree="$2"
  case "$1" in
  none) : ;;
  git-write) printf 'x\n' >"${tree}/.git/index" ;;
  new-file) printf 'b\n' >"${tree}/b" ;;
  delete-file) rm -- "${tree}/a" ;;
  rewrite-same-content) cp -- "${tree}/a" "${tree}/a.tmp" && cp -- "${tree}/a.tmp" "${tree}/a" && rm -- "${tree}/a.tmp" ;;
  chmod-roundtrip) chmod 000 -- "${tree}/a" && chmod 644 -- "${tree}/a" ;;
  retarget-symlink) ln -sfn elsewhere "${tree}/link" ;;
  chmod-directory) chmod 700 -- "${tree}/d" ;;
  new-empty-directory) mkdir -- "${tree}/newdir" ;;
  esac
}

snapshot_case snapshot-stable-without-change no none
snapshot_case snapshot-ignores-git-writes no git-write
snapshot_case snapshot-detects-new-file yes new-file
snapshot_case snapshot-detects-deleted-file yes delete-file
snapshot_case snapshot-detects-same-content-rewrite yes rewrite-same-content
snapshot_case snapshot-detects-chmod-roundtrip yes chmod-roundtrip
snapshot_case snapshot-detects-retargeted-symlink yes retarget-symlink
snapshot_case snapshot-detects-directory-mode yes chmod-directory
snapshot_case snapshot-detects-new-empty-directory yes new-empty-directory

# ---------------------------------------------------------------------------
# no-writes-*: the harnesses that regenerate a doc or flip a fixture's mode
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
