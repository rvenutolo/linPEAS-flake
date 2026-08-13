# scripts/lib/temp.sh
#
# @description Guarded temp-file creation. Source after `set -Eeuo pipefail`.
# shellcheck shell=bash

# @description Create a temp file or directory, reporting a failure as a
# could-not-run rather than as a finding. An unwritable TMPDIR makes
# `mktemp` exit 1, and an unguarded `x="$(mktemp)"` under `set -e` kills
# the caller with that same 1 — the status a lint uses for "this file
# carries a violation". A pre-commit hook reads that as "the tree is
# stale, fix it and commit", sending the operator to edit content the
# check never read. Exiting 2 from inside the command substitution
# propagates through the enclosing assignment, so the call site needs no
# guard of its own. No label argument: the caller's ERR trap already
# prints the failing line and BASH_COMMAND, so the site names itself.
# @arg $@ passed through to `mktemp` verbatim
# @stdout the created path
# @exitcode 2 the temp file or directory could not be created
function make_temp() {
  command mktemp "$@" || {
    printf '%s: cannot create a temp file (TMPDIR=%s)\n' \
      "${0##*/}" "${TMPDIR:-/tmp}" >&2
    exit 2
  }
}
