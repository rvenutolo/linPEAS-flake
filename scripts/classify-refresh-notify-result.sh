#!/usr/bin/env bash
# scripts/classify-refresh-notify-result.sh
#
# @description Classify what `renovate-flake-lock-refresh.yml`'s
# `notify` job should report. Given the `identify`, `compute-refresh`
# and `push-refresh` job results followed by `identify`'s
# `should_refresh` and `unmapped` outputs, print `failure` when a
# refresh was attempted and did not land (or could not be attempted),
# `success` when one landed or was already in place, and `skipped` for
# the steady state where the `ci` completion was not a Renovate flake
# bump. Pure and side-effect free so the decision is unit-testable
# without a workflow run.

# The whole decision lives here, in one place, because splitting it
# between a job's `if:` gate and the `result:` expression that gate
# guards lets the two disagree with nothing to notice. A gate keyed on
# job outputs cannot see a failed job — a job that fails sets no
# outputs — so a gate written that way is blind to exactly the stage
# whose failure most needs an issue, while the expression behind it
# still scores a verdict for that case.
#
# `skipped` is inert in `.github/actions/notify-workflow-result`, so
# the silent steady state is expressed as a verdict rather than as an
# absent job: the caller runs `notify` whenever `identify` ran at all
# and lets this script decide, instead of encoding half the decision in
# YAML that nothing can test.
#
# Combinations the workflow cannot produce (a refresh attempted with no
# `compute-refresh`, a silent verdict with jobs that ran) classify as
# `failure`, not `skipped`. Such a combination means the job graph
# moved, and an issue naming a drifted workflow is a better outcome
# than the silence this script exists to remove.
#
# See docs/architecture/flake-input-bumps.md.
#
# Exit codes:
#   0  classified: `failure`, `success`, or `skipped` on stdout. A
#      `failure` verdict is an answer, not this script failing, so it
#      exits 0 like the other two.
#   2  it could not classify: the argument count is not five, a job
#      result is not success|failure|cancelled|skipped, or an output is
#      not true|false|empty

set -Eeuo pipefail
IFS=$'\n\t'

readonly WANT_ARGS=5

if [[ $# -ne ${WANT_ARGS} ]]; then
  printf 'usage: %s <identify> <compute-refresh> <push-refresh> <should_refresh> <unmapped>\n' \
    "${0##*/}" >&2
  printf 'job results are success|failure|cancelled|skipped; the two outputs are true|false|empty\n' >&2
  exit 2
fi

readonly IDENTIFY="$1"
readonly COMPUTE="$2"
readonly PUSH="$3"
readonly SHOULD_REFRESH="$4"
readonly UNMAPPED="$5"

# Validate before deciding. An unrecognized token is a caller that
# renamed a job or an expression that evaluated to something other than
# a job result, and either one would otherwise land in a `*)` arm and be
# scored as a verdict.
for result in "${IDENTIFY}" "${COMPUTE}" "${PUSH}"; do
  case "${result}" in
  success | failure | cancelled | skipped) ;;
  *)
    printf 'invalid job result %q (want success|failure|cancelled|skipped)\n' \
      "${result}" >&2
    exit 2
    ;;
  esac
done
for output in "${SHOULD_REFRESH}" "${UNMAPPED}"; do
  case "${output}" in
  true | false | '') ;;
  *)
    printf 'invalid job output %q (want true|false|empty)\n' "${output}" >&2
    exit 2
    ;;
  esac
done

# A failed or cancelled `identify` sets no outputs, so nothing below
# this point could tell such a run from a clean early exit. The
# composite treats `cancelled` as an infrastructure failure, and so does
# this: a timed-out identify leaves the same unrefreshed PR behind that
# a failed one does.
if [[ ${IDENTIFY} != 'success' ]]; then
  printf 'failure\n'
  exit 0
fi

# A Renovate PR that edits `flake.nix` and maps to no flake input is a
# title shape that moved. It is reachable only after the author and
# `flake.nix` gates have both passed, so it is a finding rather than a
# skip.
if [[ ${UNMAPPED} == 'true' ]]; then
  printf 'failure\n'
  exit 0
fi

if [[ ${SHOULD_REFRESH} != 'true' ]]; then
  # The steady state: this `ci` completion was not a Renovate flake
  # bump. Both downstream jobs are gated on `should_refresh`, so either
  # having run means the gate and this verdict disagree.
  if [[ ${COMPUTE} != 'skipped' || ${PUSH} != 'skipped' ]]; then
    printf 'refresh jobs ran for a completion classified as no-refresh\n' >&2
    printf 'failure\n'
    exit 0
  fi
  printf 'skipped\n'
  exit 0
fi

# A refresh was attempted. `push-refresh` is skipped when
# `compute-refresh` produced no diff, which is the loop-breaker's
# steady state and a success.
if [[ ${COMPUTE} == 'success' ]] &&
  { [[ ${PUSH} == 'success' ]] || [[ ${PUSH} == 'skipped' ]]; }; then
  printf 'success\n'
  exit 0
fi
printf 'failure\n'
