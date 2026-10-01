# scripts/lib/repo.sh
#
# @description Guarded repository-root lookup. Source after
# `set -Eeuo pipefail`.
# shellcheck shell=bash

# @description Print the top level of the git work tree holding the
# current directory, reporting a work tree git cannot resolve as a
# could-not-run.
# Run outside a work tree (no repository, a bare repository, or inside a
# `.git` directory), `git rev-parse --show-toplevel` exits 128, and an
# unguarded `x="$(git rev-parse --show-toplevel)"` under `set -e` ends the
# caller with that 128, a status no caller reads as "could not run".
# Exiting 2 from inside the command substitution propagates through the
# enclosing assignment, so the call site needs no guard of its own; a
# `local` or `readonly` declaration on the same line would mask it, so
# assign on a line of its own. git's own diagnostic is left on stderr
# above this one, because it names the cause: no repository, no work tree,
# or a work tree git refuses to open (a `safe.directory` refusal). The
# lookup follows git's
# rules, so a set `GIT_DIR` or `GIT_WORK_TREE` decides the answer.
# @stdout the work tree's top-level path
# @exitcode 2 git is not on PATH, or git cannot resolve a work tree for the
#   current directory
function repo_toplevel() {
  local top
  if ! command -v git >/dev/null 2>&1; then
    printf '%s: git is not on PATH, so the repository root cannot be found\n' \
      "${0##*/}" >&2
    exit 2
  fi
  if ! top="$(git rev-parse --show-toplevel)"; then
    printf '%s: cannot resolve the git work tree (cwd: %s)\n' "${0##*/}" "${PWD}" >&2
    exit 2
  fi
  printf '%s\n' "${top}"
}
