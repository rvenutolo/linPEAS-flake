#!/usr/bin/env bash
# tests/lib-temp.test.sh — proves scripts/lib/temp.sh creates temp files
# and directories, passes every argument through to `mktemp` verbatim,
# and reports a creation failure as a could-not-run (exit 2) both when
# called directly and from inside a command substitution, so a caller's
# `x="$(make_temp)"` cannot leak mktemp's own exit 1 as the calling
# script's status.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly LIB="${REPO_ROOT}/scripts/lib/temp.sh"

failures=0
rc=0
work="$(mktemp --directory)"
trap 'rm --recursive --force -- "${work}"' EXIT

# Point the default temp root at the harness work dir so that a scenario
# creating a temp file with no arguments leaves it where this harness's
# own EXIT trap removes it, rather than in the system temp root where it
# would outlive the run.
mkdir --parents -- "${work}/tmproot" "${work}/probe-root"
export TMPDIR="${work}/tmproot"
export PROBE_ROOT="${work}/probe-root"

function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# @description Run a library-driving snippet as its own bash process, so
# that `make_temp`'s `exit` terminates only that process rather than this
# harness, capture its streams, and record the outcome with the
# cross-scenario discrimination gate. Sets `rc` (a plain, non-local
# variable of the calling scope) rather than returning through a `$()`
# command substitution: a substitution forks a subshell, and
# `harness_assert_record`'s pool state lives in globals that a subshell's
# exit would discard, leaving the parent with no recorded scenarios. The
# script is named after the scenario because `make_temp`'s diagnostic
# leads with `${0##*/}`, which is what lets two failure scenarios be told
# apart by the gate.
# @arg $1 scenario name  @arg $2 asserted substring ('' if none)
# @arg $3 snippet body: calls `make_temp` and prints a `kind=` line
#   classifying what it got back.
function run_scenario() {
  local -r name="$1" substring="$2" body="$3"
  local -r script="${work}/${name}.sh"
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
  bash "${script}" >"${out}" 2>"${err}" || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${outcome}"
  harness_assert_record "${name}" "${substring}" "${outcome}" "${out}" "${err}"
}

# 1. plain-file — no arguments yields a path that exists as a regular file.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'plain-file' 'kind=regular-file' '
p="$(make_temp)"
if [[ -f ${p} ]]; then
  printf "kind=regular-file\n"
else
  printf "kind=absent\n"
fi
printf "path=%s\n" "${p}"
'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'kind=regular-file' "${work}/plain-file.out"; then
  pass 'plain-file: make_temp with no arguments creates a regular file, exit 0'
else
  fail "plain-file: expected exit 0 + a regular file, got exit ${rc}"
  cat -- "${work}/plain-file.out" "${work}/plain-file.err" >&2
fi

# 2. directory — `--directory` reaches mktemp, so the path is a directory.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'directory' 'kind=directory' '
d="$(make_temp --directory)"
if [[ -d ${d} ]]; then
  printf "kind=directory\n"
else
  printf "kind=not-a-directory\n"
fi
printf "path=%s\n" "${d}"
'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'kind=directory' "${work}/directory.out"; then
  pass 'directory: --directory reaches mktemp and yields a directory, exit 0'
else
  fail "directory: expected exit 0 + a directory, got exit ${rc}"
  cat -- "${work}/directory.out" "${work}/directory.err" >&2
fi

# 3. argument-passthrough — a `--tmpdir` and a template both reach mktemp,
# so the created file lands under the caller's root with the caller's
# name prefix. Proves the helper forwards argv rather than accepting only
# the no-argument form.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'argument-passthrough' 'kind=under-caller-root' '
f="$(make_temp --tmpdir="${PROBE_ROOT}" probe.XXXXXX)"
if [[ -f ${f} && ${f} == "${PROBE_ROOT}/probe."* ]]; then
  printf "kind=under-caller-root\n"
else
  printf "kind=elsewhere\n"
fi
printf "path=%s\n" "${f}"
'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'kind=under-caller-root' \
    "${work}/argument-passthrough.out"; then
  pass 'argument-passthrough: --tmpdir and template reach mktemp verbatim, exit 0'
else
  fail "argument-passthrough: expected the file under the caller's root, got exit ${rc}"
  cat -- "${work}/argument-passthrough.out" "${work}/argument-passthrough.err" >&2
fi

# 4. tmpdir-unwritable — a temp root that does not exist makes mktemp
# fail, and the helper reports that as a could-not-run rather than
# letting mktemp's own exit 1 stand as the script's verdict. The asserted
# substring carries the script basename the diagnostic leads with, so it
# separates this scenario from the command-substitution one below, which
# emits the same failure text from a different script.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'tmpdir-unwritable' 'tmpdir-unwritable.sh: cannot create a temp file (TMPDIR=/nonexistent-temp-root-probe)' '
export TMPDIR="/nonexistent-temp-root-probe"
make_temp
printf "kind=returned-anyway\n"
'
if [[ ${rc} -eq 2 ]] &&
  grep --fixed-strings --quiet -- 'cannot create a temp file' \
    "${work}/tmpdir-unwritable.err"; then
  pass 'tmpdir-unwritable: an absent temp root is exit 2, stderr names the failure'
else
  fail "tmpdir-unwritable: expected exit 2 + temp-file failure message, got exit ${rc}"
  cat -- "${work}/tmpdir-unwritable.out" "${work}/tmpdir-unwritable.err" >&2
fi

# 5. substitution-propagates — the same failure inside `t="$(make_temp)"`
# ends the calling script with status 2. This is the property the whole
# sweep rests on: the helper's `exit` runs in the substitution's subshell,
# and the enclosing assignment carries that status out under
# `set -Eeuo pipefail`, so no call site needs a guard of its own. The
# trailing print is the negative half — reaching it would mean the caller
# carried on with an unset path.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'substitution-propagates' 'substitution-propagates.sh: cannot create a temp file (TMPDIR=/nonexistent-temp-root-probe)' '
export TMPDIR="/nonexistent-temp-root-probe"
t="$(make_temp)"
printf "kind=caller-continued path=%s\n" "${t}"
'
if [[ ${rc} -eq 2 ]] &&
  grep --fixed-strings --quiet -- 'cannot create a temp file' \
    "${work}/substitution-propagates.err" &&
  ! grep --fixed-strings --quiet -- 'kind=caller-continued' \
    "${work}/substitution-propagates.out"; then
  pass 'substitution-propagates: a make_temp failure in a substitution ends the caller at exit 2'
else
  fail "substitution-propagates: expected the caller to die at exit 2, got exit ${rc}"
  cat -- "${work}/substitution-propagates.out" "${work}/substitution-propagates.err" >&2
fi

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -gt 0 ]]; then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
