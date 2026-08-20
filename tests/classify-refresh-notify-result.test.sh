#!/usr/bin/env bash
# tests/classify-refresh-notify-result.test.sh
#
# Verdict + failure-mode matrix for
# scripts/classify-refresh-notify-result.sh. Pure classifier: three job
# results and two job outputs in, one verdict out. Offline and
# deterministic.
#
# The two rows this harness exists for sit at opposite ends of the
# matrix. A hard failure in `identify` must reach an issue: it is the
# stage whose failure is least likely to be noticed, because the
# workflow runs in reaction to someone else's PR and nobody is watching
# the Actions tab when it goes red. A `ci` completion that is not a
# Renovate flake bump must stay silent: it is the steady state for
# nearly every run, and an issue per run would bury the failures this
# workflow is built to report. A classifier that cannot tell those two
# apart is worse than none.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/classify-refresh-notify-result.sh"

failures=0

# @arg $1 description  @arg $2 expected stdout, or "<exit:N>" for a
#   non-zero exit whose exact code is the assertion
# remaining args: passed through to the classifier
function classify() {
  local -r desc="$1" want="$2"
  shift 2
  local got rc=0
  got="$(bash "${SCRIPT}" "$@" 2>/dev/null)" || rc=$?
  if [[ ${want} == "<exit:"* ]]; then
    local -r want_rc="${want#<exit:}"
    if [[ ${rc} -ne ${want_rc%>} ]]; then
      printf 'FAIL %s: exit %d, want %s\n' "${desc}" "${rc}" "${want}" >&2
      failures=1
      return
    fi
    printf 'OK   %s (exit %d)\n' "${desc}" "${rc}"
    return
  fi
  if [[ ${rc} -ne 0 ]]; then
    printf 'FAIL %s: exit %d, want %s\n' "${desc}" "${rc}" "${want}" >&2
    failures=1
    return
  fi
  if [[ ${got} != "${want}" ]]; then
    printf 'FAIL %s: got %q want %q\n' "${desc}" "${got}" "${want}" >&2
    failures=1
    return
  fi
  printf 'OK   %s\n' "${desc}"
}

# --- the failure that had no reporter ------------------------------
# A job that fails sets no outputs, so both `identify` outputs arrive
# empty. Every row below carries that shape; the verdict has to come
# from the result, since nothing else distinguishes them.
classify "identify failure reports" failure \
  failure skipped skipped '' ''
classify "identify cancelled reports" failure \
  cancelled skipped skipped '' ''

# --- the silence that has to hold ----------------------------------
# `identify` exits 0 with should_refresh=false for a PR with no open
# PR, a non-Renovate author, or no `flake.nix` in its file list. Those
# are the ordinary `ci` completions on a `renovate/*` branch.
classify "non-flake Renovate PR stays silent" skipped \
  success skipped skipped false ''
classify "unset should_refresh stays silent" skipped \
  success skipped skipped '' ''

# --- a mapped refresh ----------------------------------------------
# push-refresh is gated on compute-refresh having produced a diff, so
# its skip is the loop-breaker's steady state rather than a fault: the
# second `ci` pass finds the lock already in sync.
classify "refresh pushed" success \
  success success success true ''
classify "refresh produced no diff" success \
  success success skipped true ''
classify "compute-refresh failure reports" failure \
  success failure skipped true ''
classify "push-refresh failure reports" failure \
  success success failure true ''
classify "compute-refresh cancelled reports" failure \
  success cancelled skipped true ''

# --- a title that maps to no input ---------------------------------
# Reachable only after the author and `flake.nix` gates both pass, so a
# Renovate PR edits `flake.nix` and no input name can be derived for it.
classify "unmapped title reports" failure \
  success skipped skipped false true

# --- combinations the job graph cannot produce ---------------------
# Both downstream jobs are gated on should_refresh, so either of them
# having run alongside a no-refresh verdict means the graph moved.
# Loud beats silent: silence is the defect this classifier removes.
classify "refresh jobs ran without should_refresh" failure \
  success success skipped false ''
classify "push ran without should_refresh" failure \
  success skipped success false ''
classify "refresh attempted with no compute-refresh" failure \
  success skipped skipped true ''

# --- operational errors --------------------------------------------
# An unrecognized token means a renamed job or an expression that
# evaluated to something other than a job result. Scoring it as a
# verdict would hand back a plausible answer for a broken caller.
classify "unknown job result" "<exit:2>" \
  bogus skipped skipped '' ''
classify "unknown job output" "<exit:2>" \
  success skipped skipped yes ''
classify "no arguments" "<exit:2>"
classify "too few arguments" "<exit:2>" success skipped skipped true
classify "too many arguments" "<exit:2>" \
  success skipped skipped true '' extra

if [[ ${failures} -ne 0 ]]; then
  printf '\nclassify-refresh-notify-result: FAILURES\n' >&2
  exit 1
fi
printf '\nclassify-refresh-notify-result: all passed\n'
