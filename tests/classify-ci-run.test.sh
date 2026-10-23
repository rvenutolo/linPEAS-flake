#!/usr/bin/env bash
# tests/classify-ci-run.test.sh
#
# Verdict + per-job class matrix for scripts/classify-ci-run.sh. Pure
# classifier: one run's job JSON in, a verdict and one detail line per
# unsuccessful job out. Offline and deterministic.
#
# The rows that matter most: a bot PR retries anything until the attempt
# cap, while an automated run retries only when no job failed for a real
# reason, so a genuine regression is reported once instead of being
# retried into silence. A superseded cancel must never count.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/classify-ci-run.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/classify-ci-run"

failures=0

# @arg $1 description  @arg $2 expected exit code (must be non-zero)
# @arg $3 stdin file
# remaining args: passed through to the classifier
function expect_exit() {
  local -r desc="$1" want_rc="$2" input="$3"
  shift 3
  local rc=0
  bash "${SCRIPT}" "$@" <"${input}" >/dev/null 2>&1 || rc=$?
  if [[ ${rc} -ne ${want_rc} ]]; then
    printf 'FAIL %s: exit %d, want %d\n' "${desc}" "${rc}" "${want_rc}" >&2
    failures=1
    return
  fi
  printf 'OK   %s (exit %d)\n' "${desc}" "${rc}"
}

# @arg $1 description  @arg $2 expected stdout line 1
# @arg $3 expected detail line (exact, whole line), or "-" for no check,
#   or "none" to assert there are no detail lines, or "count:N" for N
#   detail lines
# @arg $4 stdin file
# remaining args: passed through to the classifier
function classify() {
  local -r desc="$1" want="$2" detail="$3" input="$4"
  shift 4
  local out rc=0
  out="$(bash "${SCRIPT}" "$@" <"${input}" 2>/dev/null)" || rc=$?
  if [[ ${rc} -ne 0 ]]; then
    printf 'FAIL %s: exit %d, want 0\n' "${desc}" "${rc}" >&2
    failures=1
    return
  fi
  local verdict details=''
  verdict="${out%%$'\n'*}"
  if [[ ${out} == *$'\n'* ]]; then
    details="${out#*$'\n'}"
  fi
  if [[ ${verdict} != "${want}" ]]; then
    printf 'FAIL %s: verdict %q, want %q\n' "${desc}" "${verdict}" "${want}" >&2
    failures=1
    return
  fi
  local -a lines=()
  if [[ -n ${details} ]]; then
    mapfile -t lines <<<"${details}"
  fi
  case "${detail}" in
  -) ;;
  none)
    if ((${#lines[@]} != 0)); then
      printf 'FAIL %s: unexpected detail %q\n' "${desc}" "${details}" >&2
      failures=1
      return
    fi
    ;;
  count:*)
    if ((${#lines[@]} != ${detail#count:})); then
      printf 'FAIL %s: %d detail lines, want %s\n' "${desc}" "${#lines[@]}" "${detail#count:}" >&2
      failures=1
      return
    fi
    ;;
  *)
    local line found=false
    for line in "${lines[@]}"; do
      if [[ ${line} == "${detail}" ]]; then
        found=true
      fi
    done
    if [[ ${found} != 'true' ]]; then
      printf 'FAIL %s: detail %q not in %q\n' "${desc}" "${detail}" "${details}" >&2
      failures=1
      return
    fi
    ;;
  esac
  printf 'OK   %s\n' "${desc}"
}

readonly T=$'\t'
fx() { printf '%s/%s.json' "${FIXTURES}" "$1"; }

# --- bot-pr policy: retry anything up to the attempt cap ------------
classify "bot-pr-timeout" retry "editorconfig${T}transient${T}timeout" \
  "$(fx bot-pr-timeout)" --policy bot-pr
classify "bot-pr-real-failure" retry \
  "lint${T}real${T}step:Run scripts/run-lint-group.sh" \
  "$(fx bot-pr-real-failure-2)" --policy bot-pr
classify "bot-pr-attempt-3" exhausted - \
  "$(fx bot-pr-real-failure-3)" --policy bot-pr
classify "bot-pr-superseded-only" ignore "lint${T}superseded${T}superseded" \
  "$(fx bot-pr-superseded-only)" --policy bot-pr

# --- automated policy ------------------------------------------------
classify "mixed-supersede-timeout" retry count:2 \
  "$(fx mixed-supersede-timeout)" --policy automated
classify "automated-real-plus-timeout" report - \
  "$(fx automated-real-plus-timeout)" --policy automated
classify "automated-setup-step" retry \
  "lint${T}transient${T}setup-step:Run ./.github/actions/setup-nix" \
  "$(fx automated-setup-step)" --policy automated
classify "automated-transient-attempt-3" exhausted \
  "lint${T}transient${T}timed_out" \
  "$(fx automated-transient-attempt-3)" --policy automated
classify "dispatch-timeout" report - \
  "$(fx dispatch-timeout)" --policy automated
classify "pr-event-automated" report - \
  "$(fx pr-event-timeout)" --policy automated
classify "push-non-main" report - \
  "$(fx push-non-main)" --policy automated
classify "in-progress-sibling" retry count:1 \
  "$(fx in-progress-sibling)" --policy automated
classify "runner-lost" retry "lint${T}transient${T}runner-lost" \
  "$(fx runner-lost)" --policy automated
classify "no-failed-step" retry "lint${T}transient${T}no-failed-step" \
  "$(fx no-failed-step)" --policy automated
classify "all-success" ignore none \
  "$(fx all-success)" --policy automated
classify "all-success bot-pr" ignore none \
  "$(fx all-success)" --policy bot-pr

# --- every rule pinned by a row that fails if the rule is wrong ------
classify "bot-pr-cancelled-other" ignore "lint${T}superseded${T}cancelled-other" "$(fx bot-pr-cancelled-other)" --policy bot-pr
classify "runner-shutdown" retry "lint${T}transient${T}runner-lost" "$(fx runner-shutdown)" --policy automated
classify "workflow-run-timeout" retry "lint${T}transient${T}timed_out" "$(fx workflow-run-timeout)" --policy automated
classify "setup-set-up-job" retry "lint${T}transient${T}setup-step:Set up job" "$(fx setup-set-up-job)" --policy automated
classify "setup-pre-harden" retry "lint${T}transient${T}setup-step:Pre Run step-security/harden-runner@0123456789abcdef0123456789abcdef01234567" "$(fx setup-pre-harden)" --policy automated
classify "setup-run-harden" retry "lint${T}transient${T}setup-step:Run step-security/harden-runner@0123456789abcdef0123456789abcdef01234567" "$(fx setup-run-harden)" --policy automated
classify "setup-checkout" retry "lint${T}transient${T}setup-step:Run actions/checkout@89abcdef0123456789abcdef0123456789abcdef" "$(fx setup-checkout)" --policy automated
classify "setup-app-token" retry "lint${T}transient${T}setup-step:Run actions/create-github-app-token@0123456789abcdef0123456789abcdef01234567" "$(fx setup-app-token)" --policy automated
classify "post-step-real" report "lint${T}real${T}step:Post Run actions/checkout@89abcdef0123456789abcdef0123456789abcdef" "$(fx post-step-real)" --policy automated
# A release-on-bump re-run is not idempotent, so the automated policy
# reports its transient instead of retrying it; the bot-pr policy is
# unaffected, which pins the exclusion to the one policy that names it.
classify "release-on-bump-automated" report "lint${T}transient${T}setup-step:Run ./.github/actions/setup-nix" "$(fx release-on-bump-setup-step)" --policy automated
classify "release-on-bump-bot-pr" retry "lint${T}transient${T}setup-step:Run ./.github/actions/setup-nix" "$(fx release-on-bump-setup-step)" --policy bot-pr
classify "runner-lost-over-real-step" retry "lint${T}transient${T}runner-lost" "$(fx runner-lost-over-real-step)" --policy automated

# --- operational errors ----------------------------------------------
TMP_DIR="$(mktemp --directory)"
readonly TMP_DIR
trap 'rm --force -- "${TMP_DIR}/bad.json" "${TMP_DIR}/empty.json"; rmdir -- "${TMP_DIR}"' EXIT
printf 'not json' >"${TMP_DIR}/bad.json"
printf '{}' >"${TMP_DIR}/empty.json"
# A malformed payload is a could-not-classify, never a verdict.
expect_exit "bad-policy" 2 "$(fx all-success)" --policy nope
expect_exit "missing-policy" 2 "$(fx all-success)"
expect_exit "malformed-json" 2 "${TMP_DIR}/bad.json" --policy automated
expect_exit "missing-jobs" 2 "${TMP_DIR}/empty.json" --policy automated
classify "print-max-attempts" 3 none /dev/null --print-max-attempts

if [[ ${failures} -ne 0 ]]; then
  printf '\nclassify-ci-run: FAILURES\n' >&2
  exit 1
fi
printf '\nclassify-ci-run: all passed\n'
