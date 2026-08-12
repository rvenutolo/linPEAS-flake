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
# @arg $1 name of the array to fill
# @arg $@ the producer command and its arguments
# @exitcode 2 the producer failed, or the scan set was empty while
#   LINT_ALLOW_EMPTY_SCAN was unset
function enumerate_into() {
  local -r __enum_target="$1"
  shift
  # Named distinctly so a caller passing a plainly-named array cannot
  # collide with the nameref, which bash rejects as a circular reference.
  local -n __enum_out_ref="${__enum_target}"
  __enum_out_ref=()

  local __enum_tmp
  __enum_tmp="$(mktemp)"
  if ! "$@" >"${__enum_tmp}"; then
    rm --force -- "${__enum_tmp}"
    printf '%s: %s failed enumerating the scan set\n' "${0##*/}" "$1" >&2
    exit 2
  fi

  local __enum_item
  while IFS= read -r -d '' __enum_item; do
    [[ -n ${__enum_item} ]] || continue
    __enum_out_ref+=("${__enum_item}")
  done <"${__enum_tmp}"
  rm --force -- "${__enum_tmp}"

  if ((${#__enum_out_ref[@]} == 0)) && [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
    printf '%s: enumerated 0 files via %s — a real tree cannot have an empty scan set; set LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate\n' \
      "${0##*/}" "$1" >&2
    exit 2
  fi
}
