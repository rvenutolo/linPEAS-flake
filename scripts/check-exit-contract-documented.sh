#!/usr/bin/env bash
# scripts/check-exit-contract-documented.sh
#
# @description Lint: every script directly under `scripts/` that can reach
# exit 2 says so in its header. Exit 2 means the check could not run — a
# required tool absent, an input missing or malformed — and exit 1 means
# it ran and found a violation. A header promising only 0 and 1 tells a
# reader, and anyone wiring the script into a new caller, that a
# could-not-run cannot happen; a caller written against that promise
# treats one as a finding and reports a violation nobody observed.
#
# A script can reach exit 2 two ways, and both count:
#   - a literal `exit 2` / `return 2` on a line that is not a comment
#   - a call to a library helper that exits 2 in the caller's shell:
#     require_tool, enumerate_into, glob_into, filter_into,
#     require_json_payload, payload_source_into, read_json_payload_into,
#     make_temp
# Detection is textual and direct-call-only: a helper reached through
# another helper is already covered by that helper's own call site, and
# chasing the source graph would report a script for code it never runs.
#
# The header is every line above the first line that is neither blank nor
# a comment. It is unwrapped before matching, because these contracts
# routinely wrap mid-sentence and a line-oriented match cannot see a
# clause split across two lines.
#
# Four contract shapes count as documenting exit 2, which is every shape
# the tree uses:
#   Exits 2 when …                        (a dedicated sentence)
#   Exits 0 on …, 1 on …, 2 on …          (a comma-separated list)
#   Exit: 0 …, 3 …, 2 usage error.        (the same list, any order)
#   Exit codes:  … a `2` item line …      (an enumerated block)
# The list forms match only within one sentence, so a `2` in unrelated
# prose later in the header does not excuse a missing contract. The item
# form requires the 2 to stand alone as a token: `2FA` and `v2` are prose,
# not exit codes, and one of them appears in a header this rule covers.
#
# Scope is `scripts/*.sh` only. Libraries under `scripts/lib/` exit in
# their caller's shell and have no standalone contract of their own —
# documenting that exit is the obligation of the callers this rule reads.
#
# No exemption marker. Every script can describe its own exit codes, so a
# hit is always fixed by writing the sentence rather than by excusing the
# script.
#
# Honors SCRIPTS_DIR_OVERRIDE (default: scripts) and
# LINT_ALLOW_EMPTY_SCAN=1 for fixtures.
#
# Exits 0 when every script that can reach exit 2 documents it, 1 on any
# script that cannot. Exits 2 when the check cannot run: the scan set
# matches no script, which is a could-not-run rather than a clean tree.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"

readonly SCRIPTS_DIR="${SCRIPTS_DIR_OVERRIDE:-scripts}"

# Helpers that exit 2 in the shell that calls them.
readonly HELPER_RE='require_tool|enumerate_into|glob_into|filter_into|require_json_payload|payload_source_into|read_json_payload_into|make_temp'

# @description Emit a script's header: every line above the first that is
#              neither blank nor a comment.
# @arg $1 script path
function header_of() {
  # Fed on stdin rather than as an operand: awk has no `--` end-of-options
  # separator, so a path could otherwise be read as an option.
  awk '/^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next } { exit }' <"$1"
}

# @description Emit the header as one line, comment markers stripped and
#              runs of whitespace squeezed, so a clause that wraps reads
#              as the single sentence it is.
# @arg $1 script path
function header_unwrapped() {
  header_of "$1" | sed 's/^[[:space:]]*#\!.*//; s/^[[:space:]]*#[[:space:]]\?//' |
    tr '\n' ' ' | tr -s '[:space:]' ' '
}

# @description Succeed when the script can reach exit 2.
# @arg $1 script path
function reaches_exit_two() {
  local -r file="$1"
  # Comment lines are dropped first: a header describing exit 2 must not
  # be read as code producing it, or every compliant script would look
  # like it needs the sentence it already has.
  local code
  code="$(grep -v '^[[:space:]]*#' <"${file}" || true)"
  grep -qE '\b(exit|return) 2\b' <<<"${code}" && return 0
  grep -qE "\\b(${HELPER_RE})\\b" <<<"${code}" && return 0
  return 1
}

# @description Succeed when the header documents exit 2.
# @arg $1 script path
function documents_exit_two() {
  local -r file="$1"
  local unwrapped
  unwrapped="$(header_unwrapped "${file}")"

  # A dedicated sentence: "Exits 2 when …", or prose naming "exit 2".
  grep -qiE '\bexits?[[:space:]]+2([^0-9A-Za-z]|$)' <<<"${unwrapped}" && return 0

  # A comma-separated list inside one sentence: "Exits 0 on …, 1 …, 2 …".
  # The sentence, not a character budget, is the bound: one contract here
  # enumerates its exit-1 causes at length before reaching its exit-2
  # clause, and any fixed window short enough to be safe would cut it
  # off. A period still ends the search, so a stray 2 in a later sentence
  # excuses nothing.
  grep -qiE '\bexits?\b[^.]*,[[:space:]]*2([^0-9A-Za-z]|$)' <<<"${unwrapped}" && return 0

  # An enumerated block: an "Exit codes:" heading plus a `2` item line.
  if grep -qiE 'exit[[:space:]]+codes?:' <<<"${unwrapped}"; then
    header_of "${file}" | grep -qE '^[[:space:]]*#[[:space:]]+2([^0-9A-Za-z]|$)' && return 0
  fi

  return 1
}

function main() {
  local -a scripts=()
  glob_into scripts 'scripts' "${SCRIPTS_DIR}"/*.sh

  local file reachable=0 documented=0 failed=0
  for file in "${scripts[@]}"; do
    reaches_exit_two "${file}" || continue
    reachable=$((reachable + 1))
    if documents_exit_two "${file}"; then
      documented=$((documented + 1))
      continue
    fi
    printf '%s: can reach exit 2 but its header documents no exit-2 case\n' "${file}" >&2
    failed=1
  done

  if ((failed)); then
    printf '\nexit 2 means the check could not run; a header promising only 0\n' >&2
    printf 'and 1 makes a caller report a could-not-run as a finding\n' >&2
    exit 1
  fi

  printf 'exit-contract-documented: ok — scanned %d script(s), %d can reach exit 2, all %d document it\n' \
    "${#scripts[@]}" "${reachable}" "${documented}"
}

main "$@"
