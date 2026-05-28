#!/usr/bin/env bash
# scripts/check-scorecard-threshold.sh
#
# @description Reads OSSF Scorecard JSON on stdin; exits 1 if any
# check scored below 10. Prints offender names + scores to stderr.

# Threshold enforcer for the scorecard-drift-check workflow. The
# scorecard CLI returns 0 on completion regardless of per-check
# scores — only infra errors are nonzero. This script imposes a
# strict "every included check must score 10" policy so that any
# drop is surfaced via the workflow's failure path
# (notify-workflow-result → deduped tracking issue).
#
# Input: scorecard --format=json on stdin.
# Output: offender lines on stderr ("Maintained: 7"), one per line.
# Exit:   0 = all included checks scored 10; 1 = at least one < 10
#         or JSON is malformed (pipefail).

set -Eeuo pipefail
IFS=$'\n\t'

# Slurp stdin into a variable so we can reject empty input explicitly.
# Without this guard, an empty stdin (scorecard crashed or wrote
# nothing) silently flows through `jq '.checks[]'` as zero documents
# and the script exits 0 — a silent no-op masquerading as success.
# The drift-check workflow's `set -Eeuo pipefail` should already trip
# on a nonzero scorecard exit before this script runs, but the guard
# here is belt-and-braces against any "scorecard wrote nothing but
# exited 0" path.
payload="$(cat)"
if [[ -z ${payload} ]]; then
  printf 'scorecard threshold check failed — stdin was empty (scorecard produced no output)\n' >&2
  exit 1
fi

# Parse stdin as scorecard JSON, emit "<name>: <score>" lines for
# every check with score < 10. jq exits nonzero on malformed input;
# the if-guard converts that to exit 1 with a clear message.
if ! offenders="$(jq --raw-output '
  .checks[]
  | select(.score < 10)
  | "\(.name): \(.score)"
' <<<"${payload}")"; then
  printf 'scorecard threshold check failed — could not parse scorecard JSON on stdin\n' >&2
  exit 1
fi

if [[ -n ${offenders} ]]; then
  printf 'scorecard threshold breached — the following check(s) scored below 10:\n' >&2
  printf '%s\n' "${offenders}" >&2
  exit 1
fi
exit 0
