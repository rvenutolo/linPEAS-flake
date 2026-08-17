# scripts/lib/enumerate.sh
#
# @description NUL-safe filesystem enumeration with producer-status and
# breadth assertions. A path is the one shell datum whose byte space
# includes the newline delimiter, so a line-oriented handoff can drop a
# file that exists: `git ls-files` C-quotes such a name onto one line,
# `find` splits it across two, and either way the consumer's `[[ -f ]]`
# gate skips it while the scan still reports a plausible file count.
# Source after `set -Eeuo pipefail`.
# shellcheck shell=bash

# The library directory is resolved by parameter expansion rather than by
# `readlink`/`dirname`, so a script whose PATH is missing the tool it is
# about to guard dies in its own guard naming that tool, not at this line
# naming `readlink`. The fallback covers an invocation with a bare
# filename, where the expansion strips nothing. This library resolves its
# own directory into `_lib_self_dir` rather than `_lib_dir`: a sourcing
# script sets `_lib_dir` for its own subsequent `source` lines (and any
# later use of the variable), and this file is sourced from a different
# directory than the caller, so reusing the name would overwrite it.
_lib_self_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_self_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_self_dir=.; fi
# shellcheck source=scripts/lib/temp.sh
source "${_lib_self_dir}/temp.sh"

# @description Run a NUL-emitting enumeration into an array, asserting
# both that the producer succeeded and that it found something. Breadth
# is asserted rather than inferred, because a producer that exits 0 with
# empty output is exactly the failure a status check cannot see:
# `GIT_INDEX_FILE=/nonexistent git ls-files` exits 0 and emits nothing,
# which reads as a clean tree. The producer writes to a temp file rather
# than a process substitution: a procsub discards the status this
# function exists to check, and is banned repo-wide for that reason. The
# temp file is removed on every return path instead of under a trap,
# because traps are global in bash and callers install their own.
# The temp file comes from `make_temp`, not from a bare `mktemp`:
# an unwritable `TMPDIR` makes `mktemp` exit non-zero, and an unguarded
# failed assignment kills the calling script with mktemp's own exit
# status (1) — a could-not-run reported as "ran and found a violation"
# inside the one function whose job is making sure that never happens.
# The read loop's `|| [[ -n ${__enum_item} ]]` clause keeps a final
# record that has no trailing NUL: `read -r -d ''` reports that record as
# a failure even though it populated the variable, so a loop keyed only
# on read's exit status silently drops the last path of a truncated or
# malformed producer — the exact silent-drop failure this library exists
# to end. `git ls-files -z` and `find -print0` both terminate every
# record including the last, so this only fires on a broken producer.
# @arg $1 name of the array to fill
# @arg $2 human-readable label naming the producer, used verbatim in both
#   diagnostics below. Callers supply this rather than it being derived
#   from argv[0]: argv[0] of `git ls-files -z ...` is just `git`, and a
#   same-file wrapper function's name is even less informative to an
#   operator reading the message.
# @arg $@ the producer command and its arguments
# @exitcode 2 the producer failed, or the scan set was empty while
#   LINT_ALLOW_EMPTY_SCAN was unset
function enumerate_into() {
  local -r __enum_target="$1" __enum_label="$2"
  shift 2
  # Named distinctly so a caller passing a plainly-named array cannot
  # collide with the nameref, which bash rejects as a circular reference.
  local -n __enum_out_ref="${__enum_target}"
  __enum_out_ref=()

  local __enum_tmp
  __enum_tmp="$(make_temp)"
  if ! "$@" >"${__enum_tmp}"; then
    rm --force -- "${__enum_tmp}"
    printf '%s: %s failed enumerating the scan set\n' "${0##*/}" "${__enum_label}" >&2
    exit 2
  fi

  local __enum_item
  while IFS= read -r -d '' __enum_item || [[ -n ${__enum_item} ]]; do
    [[ -n ${__enum_item} ]] || continue
    __enum_out_ref+=("${__enum_item}")
  done <"${__enum_tmp}"
  rm --force -- "${__enum_tmp}"

  if ((${#__enum_out_ref[@]} == 0)) && [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
    printf '%s: enumerated 0 files via %s — a real tree cannot have an empty scan set; set LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate\n' \
      "${0##*/}" "${__enum_label}" >&2
    exit 2
  fi
}

# @description Fill an array from one or more globs, asserting the match
# set is non-empty. The glob analogue of `enumerate_into`: under
# `nullglob` a pattern that matches nothing expands to nothing, the loop
# body never runs, no violation is found and the lint exits 0 — a scan
# root that exists and holds nothing is scored a clean tree. Patterns
# arrive as strings and are expanded here rather than at the call site,
# because a caller that has not set `nullglob` would otherwise hand this
# function the literal unexpanded pattern and it would count as one
# match — the helper vouching for exactly the tree it exists to catch.
# `globstar` is left as the caller set it, so a `**` pattern keeps the
# reach it already had.
# @arg $1 name of the array to fill
# @arg $2 human-readable label naming the scan set, used in the diagnostic
# @arg $@ the glob patterns, quoted so they reach this function unexpanded
# @exitcode 2 the match set was empty while LINT_ALLOW_EMPTY_SCAN was unset
function glob_into() {
  local -r __glob_target="$1" __glob_label="$2"
  shift 2
  local -n __glob_out_ref="${__glob_target}"
  __glob_out_ref=()

  local __glob_had_nullglob=0
  shopt -q nullglob && __glob_had_nullglob=1
  shopt -s nullglob

  local __glob_pat
  local -a __glob_batch=()
  for __glob_pat in "$@"; do
    # Empty IFS so the unquoted expansion below undergoes pathname
    # expansion without word splitting: a path holding a space is one
    # match, not two.
    local IFS=''
    # shellcheck disable=SC2206 # deliberate glob expansion of a pattern string
    __glob_batch=(${__glob_pat})
    __glob_out_ref+=("${__glob_batch[@]}")
  done

  ((__glob_had_nullglob == 1)) || shopt -u nullglob

  if ((${#__glob_out_ref[@]} == 0)) && [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
    printf '%s: matched 0 files via %s — a real tree cannot have an empty scan set; set LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate\n' \
      "${0##*/}" "${__glob_label}" >&2
    exit 2
  fi
}

# @description Narrow an enumerated path list to what a filter selects,
# asserting the selection is not empty. `enumerate_into` and `glob_into`
# assert the breadth of a scan set as it is produced; a filter applied
# afterwards can throw all of it away again, and neither helper can see
# that happen. A filter naming a file the tree does not hold leaves no
# path to walk: the loop body never runs, no violation is found, and the
# run exits 0 — the same clean line a genuinely clean tree prints. So the
# selection is asserted where it is made. An empty filter value selects
# everything, which keeps a caller that may or may not be filtering on
# one code path rather than branching around this call.
# @arg $1 name of the array to fill
# @arg $2 human-readable label naming the scan set, used in the diagnostic
# @arg $3 the filter value: a basename to select, or empty to select all
# @arg $@ the paths to select from
# @exitcode 2 the selection was empty while LINT_ALLOW_EMPTY_SCAN was unset
function filter_into() {
  local -r __filter_target="$1" __filter_label="$2" __filter_value="$3"
  shift 3
  # Named distinctly so a caller passing a plainly-named array cannot
  # collide with the nameref, which bash rejects as a circular reference.
  local -n __filter_out_ref="${__filter_target}"
  __filter_out_ref=()

  local -r __filter_input_count=$#
  local __filter_path
  for __filter_path in "$@"; do
    # Basename compared by parameter expansion rather than by `basename`,
    # which would fork once per path in the scan set. The comparison is
    # equality, not a suffix test: `b.yml` must not select `ab.yml`.
    if [[ -n ${__filter_value} && ${__filter_path##*/} != "${__filter_value}" ]]; then
      continue
    fi
    __filter_out_ref+=("${__filter_path}")
  done

  ((${#__filter_out_ref[@]} > 0)) && return 0
  [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]] || return 0

  # Two arms, because the two causes are different operator problems: a
  # filter that named a file this tree does not hold, and a caller that
  # handed in nothing to select from. One message would misdescribe one
  # of them.
  if [[ -n ${__filter_value} ]]; then
    printf '%s: filter %q selected 0 of %d files for %s — the filter matched nothing; set LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate\n' \
      "${0##*/}" "${__filter_value}" "${__filter_input_count}" "${__filter_label}" >&2
  else
    printf '%s: selected 0 files for %s — the input scan set was empty; set LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate\n' \
      "${0##*/}" "${__filter_label}" >&2
  fi
  exit 2
}
