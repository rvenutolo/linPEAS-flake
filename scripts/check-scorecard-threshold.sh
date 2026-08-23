#!/usr/bin/env bash
# scripts/check-scorecard-threshold.sh
#
# @description Reads OSSF Scorecard JSON on stdin; exits 1 if any
# check scored below 10, exits 2 if stdin cannot be read as scorecard
# JSON at all. Prints offender names + scores, or the could-not-run
# diagnostic, to stderr.

# Threshold enforcer for the scorecard-drift-check workflow. The
# scorecard CLI returns 0 on completion regardless of per-check
# scores — only infra errors are nonzero. This script imposes a
# strict "every included check must score 10" policy so that any
# drop is surfaced via the workflow's failure path
# (notify-workflow-result → deduped tracking issue).
#
# Input: scorecard --format=json on stdin.
# Output: offender lines on stderr ("Maintained: 7"), one per line.
# Exit:   0 = all included checks scored 10; 1 = at least one < 10;
#         2 = stdin is empty, whitespace-only, not valid JSON, or its
#         top level is not an object carrying a `.checks` array — none
#         of those states says anything about actual check scores, so
#         none may be reported as a passing or failing threshold.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/payload.sh
source "${_lib_dir}/lib/payload.sh"

# Slurp stdin into a variable rather than piping it straight into jq: a
# shape gate has to inspect the whole payload before any read below
# relies on its structure.
payload="$(cat)"

# stdin is the scorecard CLI's own JSON output, which carries no shape
# guarantee before a gate confirms it: an infra fault upstream, a
# truncated write, or a run that produced no output could each leave
# stdin empty, whitespace-only, or not valid JSON. A whitespace-only
# payload is the sharpest case — unguarded, it reads to `jq '.checks[]'`
# as zero documents, and the script would exit 0 as if every included
# check had scored 10, a clean pass fabricated from no data at all.
# Routing every case through the shared gate turns each into an
# explicit could-not-run instead.
require_json_payload 'stdin' "${payload}" '
  if type != "object" then "payload is \(type), want object"
  elif (.checks | type) != "array" then ".checks is \(.checks | type), want array"
  elif any(.checks[]; type != "object") then "a .checks entry is not an object"
  else empty
  end'

# Emit "<name>: <score>" lines for every check scoring below 10. The
# gate above has already confirmed the payload parses, that `.checks` is
# an array, and that every entry in it is an object — which is what
# makes the `.score` read below total. An array of scalars would pass a
# gate that stopped at the array and then kill this read with jq's own
# exit 5, outside the convention entirely.
offenders="$(jq --raw-output '
  .checks[]
  | select(.score < 10)
  | "\(.name): \(.score)"
' <<<"${payload}")"

if [[ -n ${offenders} ]]; then
  printf 'scorecard threshold breached — the following check(s) scored below 10:\n' >&2
  printf '%s\n' "${offenders}" >&2
  exit 1
fi
exit 0
