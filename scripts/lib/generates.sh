# scripts/lib/generates.sh
#
# @description `@generates` / `@generates-block` annotation parsing.
# Source after `set -Eeuo pipefail`.
# shellcheck shell=bash

# @description Read the comment header of each named script and emit one
# record per output declaration, in file order. Parsing only: the caller
# chooses which scripts to hand over, and the caller tallies what it
# needs — duplicates are emitted as separate records because one caller
# counts declarations while deduplicating paths into a map.
#
# The header ends at the first line that is neither a comment nor blank,
# so an annotation sitting in the body beside the code is not a
# declaration; blank lines separate paragraphs of a header rather than
# ending it. The plain name is a proper prefix of the block name, so the
# two are kept apart by two independent means at once: each pattern
# demands whitespace between the annotation name and its path, which is
# what stops the plain pattern from matching a block line, and the
# if/elif chain settles the longer name first so the kinds stay right
# even if that whitespace requirement is ever loosened.
#
# A read fault is reported by the return status rather than left to
# errexit, because every call site captures this in a command
# substitution inside an `if` — a context where errexit is suppressed —
# so a fault that only set `$?` would reach the caller as a short record
# stream, indistinguishable from scripts that declared nothing, and be
# scored as agreement.
# @arg $@ script paths to parse
# @stdout one record per declaration, `<kind>\037<path>\037<script-path>`,
#   where `<kind>` is `generates` or `generates-block`
# @exitcode 0 every named path was read, including when none declared anything
# @exitcode 1 at least one named path could not be read
function generator_declarations() {
  local script line
  local status=0
  for script in "$@"; do
    if [[ ! -r ${script} ]]; then
      status=1
      continue
    fi
    # `|| [[ -n ... ]]` keeps a final line with no trailing newline, which
    # read reports as a failure even after populating the variable.
    while IFS= read -r line || [[ -n ${line} ]]; do
      [[ ${line} =~ ^[[:space:]]*$ ]] && continue
      [[ ${line} == '#'* ]] || break
      if [[ ${line} =~ ^#[[:space:]]+@generates-block[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
        printf '%s\037%s\037%s\n' 'generates-block' "${BASH_REMATCH[1]}" "${script}"
      elif [[ ${line} =~ ^#[[:space:]]+@generates[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
        printf '%s\037%s\037%s\n' 'generates' "${BASH_REMATCH[1]}" "${script}"
      fi
    done <"${script}"
  done
  return "${status}"
}
