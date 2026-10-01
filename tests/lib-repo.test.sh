#!/usr/bin/env bash
# @subject scripts/lib/repo.sh
# tests/lib-repo.test.sh — proves scripts/lib/repo.sh prints the work
# tree's top level from anywhere inside it, and reports every place that is
# not inside a work tree (no repository, a bare repository, a `.git`
# directory, a work tree git refuses, no git on PATH) as a could-not-run (exit 2) naming the calling
# script, both called directly and from inside a command substitution, so a
# caller's `x="$(repo_toplevel)"` cannot leak git's own 128.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly LIB="${REPO_ROOT}/scripts/lib/repo.sh"

failures=0
rc=0
work="$(mktemp --directory)"
trap 'rm --recursive --force -- "${work}"' EXIT

# Fixtures: a work tree with a subdirectory and a linked worktree, a bare
# repository, and a plain directory. The ceiling stops git's upward search
# at the work dir, so a TMPDIR that sits inside some repository cannot turn
# the plain directory into part of it.
export GIT_CEILING_DIRECTORIES="${work}"
readonly WT="${work}/wt"
git init --quiet -- "${WT}"
mkdir --parents -- "${WT}/sub/deeper" "${work}/plain" "${work}/scripts"
git -C "${WT}" -c user.name=t -c user.email=t@example.invalid \
  commit --quiet --allow-empty --message=init
git -C "${WT}" worktree add --quiet --detach -- "${work}/linked"
git init --quiet --bare -- "${work}/bare.git"

function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# @description Run a library-driving snippet as its own bash process from a
# given directory, so that `repo_toplevel`'s `exit` ends only that process,
# capture its streams, and record the outcome with the cross-scenario
# discrimination gate. Sets `rc` in the calling scope rather than returning
# through a command substitution, whose subshell would discard the gate's
# pool state. The script is named after the scenario because the
# diagnostic leads with `${0##*/}`.
# @arg $1 scenario name  @arg $2 asserted substring  @arg $3 directory to
#   run in  @arg $4 snippet body
function run_scenario() {
  local -r name="$1" substring="$2" dir="$3" body="$4"
  local -r script="${work}/scripts/${name}.sh"
  local -r out="${work}/${name}.out"
  local -r err="${work}/${name}.err"
  local -r outcome="${work}/${name}.outcome"
  rc=0
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -Eeuo pipefail\n'
    printf "IFS=\$'\\\\n\\\\t'\n"
    printf 'source %q\n' "${LIB}"
    printf '%s\n' "${body}"
  } >"${script}"
  (cd -- "${dir}" && bash "${script}") >"${out}" 2>"${err}" || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${outcome}"
  harness_assert_record "${name}" "${substring}" "${outcome}" "${out}" "${err}"
}

# @description Check a success scenario: exit 0 and a first stdout line
# naming exactly the expected top level. The second line, the directory the
# snippet ran in, keeps scenarios that resolve to one root apart.
# @arg $1 scenario name  @arg $2 expected path  @arg $3 description
function expect_top() {
  local -r name="$1" want="$2" what="$3"
  local got
  got="$(<"${work}/${name}.out")"
  if [[ ${rc} -eq 0 && ${got%%$'\n'*} == "top=${want}" ]]; then
    pass "${name}: ${what}, exit 0"
  else
    fail "${name}: expected exit 0 and top=${want}, got exit ${rc} and '${got}'"
    cat -- "${work}/${name}.err" >&2
  fi
}

# @description Check a failure scenario: exit 2, the diagnostic on stderr,
# and the snippet's trailing print never reached.
# @arg $1 scenario name  @arg $2 expected diagnostic  @arg $3 description
function expect_could_not_run() {
  local -r name="$1" want="$2" what="$3"
  if [[ ${rc} -eq 2 ]] &&
    grep --fixed-strings --quiet -- "${want}" "${work}/${name}.err" &&
    ! grep --fixed-strings --quiet -- 'continued' "${work}/${name}.out"; then
    pass "${name}: ${what}, exit 2"
  else
    fail "${name}: expected exit 2 with '${want}', got exit ${rc}"
    cat -- "${work}/${name}.out" "${work}/${name}.err" >&2
  fi
}

# shellcheck disable=SC2016 # snippets are bash source text for a child process, not text to expand here
readonly PRINT_TOP='t="$(repo_toplevel)"
printf "top=%s\ncwd=%s\n" "${t}" "${PWD}"'

# 1. at-top — at the work tree's top level the helper prints that path.
run_scenario 'at-top' "top=${WT}" "${WT}" "${PRINT_TOP}"
expect_top 'at-top' "${WT}" 'the top level resolves to itself'

# 2. subdirectory — two levels down it still prints the top level.
run_scenario 'subdirectory' "top=${WT}" "${WT}/sub/deeper" "${PRINT_TOP}"
expect_top 'subdirectory' "${WT}" 'a subdirectory resolves to the top level'

# 3. linked-worktree — a linked worktree is its own work tree.
run_scenario 'linked-worktree' "top=${work}/linked" "${work}/linked" "${PRINT_TOP}"
expect_top 'linked-worktree' "${work}/linked" 'a linked worktree resolves to its own root'

# 4. no-repository — outside any repository: exit 2, naming the script and
# the directory, and the caller does not carry on with an empty root.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'no-repository' "no-repository.sh: cannot resolve the git work tree (cwd: ${work}/plain)" \
  "${work}/plain" 't="$(repo_toplevel)"
printf "continued top=%s\n" "${t}"'
expect_could_not_run 'no-repository' "no-repository.sh: cannot resolve the git work tree (cwd: ${work}/plain)" \
  'no repository is a could-not-run that ends the caller'

# 5. bare-repository — a bare repository has no work tree.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'bare-repository' "bare-repository.sh: cannot resolve the git work tree (cwd: ${work}/bare.git)" \
  "${work}/bare.git" 't="$(repo_toplevel)"
printf "continued top=%s\n" "${t}"'
expect_could_not_run 'bare-repository' 'bare-repository.sh: cannot resolve the git work tree' \
  'a bare repository is a could-not-run'

# 6. inside-git-dir — the `.git` directory of a work tree is not in it.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'inside-git-dir' "inside-git-dir.sh: cannot resolve the git work tree (cwd: ${WT}/.git)" \
  "${WT}/.git" 't="$(repo_toplevel)"
printf "continued top=%s\n" "${t}"'
expect_could_not_run 'inside-git-dir' 'inside-git-dir.sh: cannot resolve the git work tree' \
  'a .git directory is a could-not-run'

# 7. direct-call — called as a plain command rather than in a substitution,
# the helper's own exit ends the script with 2.
run_scenario 'direct-call' 'direct-call.sh: cannot resolve the git work tree' \
  "${work}/plain" 'repo_toplevel
printf "continued\n"'
expect_could_not_run 'direct-call' 'direct-call.sh: cannot resolve the git work tree' \
  'a direct call outside a work tree exits 2'

# 8. git-absent — with no git on PATH the cause is the missing tool, not a
# missing work tree, even inside one.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'git-absent' 'git-absent.sh: git is not on PATH' "${WT}" 'PATH=/nonexistent-path-probe
t="$(repo_toplevel)"
printf "continued top=%s\n" "${t}"'
expect_could_not_run 'git-absent' 'git-absent.sh: git is not on PATH' \
  'git missing from PATH is a could-not-run naming git'

# 9. refused-work-tree — git refuses a work tree it judges to belong to
# someone else (`safe.directory`). git's own line names that cause and is
# left on stderr above the helper's. GIT_TEST_ASSUME_DIFFERENT_OWNER is
# git's own switch for producing that refusal without a second user. The
# global and system config are set aside, because a `safe.directory`
# entry there lets git open the work tree anyway, as it did on the CI
# runner.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'refused-work-tree' 'detected dubious ownership' "${WT}" 'export GIT_TEST_ASSUME_DIFFERENT_OWNER=1
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
t="$(repo_toplevel)"
printf "continued top=%s\n" "${t}"'
expect_could_not_run 'refused-work-tree' 'refused-work-tree.sh: cannot resolve the git work tree' \
  'a refused work tree is a could-not-run with git naming the cause'

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -gt 0 ]]; then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
