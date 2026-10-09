# scripts/lib/scratch-tree.sh
#
# @description Run a harness against a scratch copy of the work tree. A
# harness that exercises a generator against the real docs would otherwise
# rewrite tracked files in the operator's checkout, replacing an uncommitted
# edit inside a generated block, and a run killed between the write and its
# restore leaves the doc drifted. The harness calls `reexec_in_scratch_tree`
# right after its preamble: the first run copies the tree, re-runs the same
# harness inside the copy with `SCRATCH_TREE_ACTIVE` set, removes the copy
# and exits with the child's status; the child's call returns at once, and
# its `git rev-parse --show-toplevel` then resolves to the copy. Source
# after `set -Eeuo pipefail`.
# shellcheck shell=bash

_lib_self_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_self_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_self_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_self_dir}/enumerate.sh"
# shellcheck source=scripts/lib/repo.sh
source "${_lib_self_dir}/repo.sh"

# @description Run git with the repository-selecting variables removed. A
# hook or a linked worktree exports `GIT_DIR`, `GIT_WORK_TREE` or
# `GIT_INDEX_FILE`, and any of them would point `git -C <dir>` back at the
# repository the copy exists to protect.
# @arg $@ git arguments
function _scratch_git() {
  env --unset=GIT_DIR --unset=GIT_WORK_TREE --unset=GIT_INDEX_FILE \
    --unset=GIT_COMMON_DIR --unset=GIT_OBJECT_DIRECTORY \
    git -c user.name=scratch -c user.email=scratch@invalid \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}

# @description Copy the tracked files, as they are on disk, into a new
# directory and commit them there, so the copy is a work tree of its own.
# A tracked file deleted in the source is left out of the copy and out of
# its index. Uncommitted edits to tracked files are carried over; untracked
# and ignored files are not.
# @arg $1 source work tree
# @arg $2 destination directory, which must exist and be empty
# @exitcode 2 the enumeration, the copy or the commit failed
function stage_scratch_tree() {
  local -r src="$1" dest="$2"
  local -a tracked=()
  enumerate_into tracked 'tracked files' \
    env --unset=GIT_DIR --unset=GIT_WORK_TREE --unset=GIT_INDEX_FILE \
    git -C "${src}" ls-files -z --cached
  printf '%s\0' "${tracked[@]}" |
    tar --directory="${src}" --null --files-from=- --ignore-failed-read \
      --create |
    tar --directory="${dest}" --extract --same-permissions
  _scratch_git -C "${dest}" init --quiet
  printf '%s\0' "${tracked[@]}" |
    _scratch_git -C "${dest}" update-index --add --remove -z --stdin
  _scratch_git -C "${dest}" commit --quiet --no-verify --message scratch
}

# @description Re-run the calling harness inside a scratch copy of the work
# tree it was started from, then exit with the copy run's status. Returns
# without doing anything when the caller is already that copy run. The
# copy is removed on every exit path of the parent, including a signal.
# Call it after the harness's own preamble and before any statement that
# writes.
# @arg $@ the harness's own arguments, passed through unchanged
# @exitcode 2 the harness is not inside the work tree, or the copy failed
function reexec_in_scratch_tree() {
  if [[ -n ${SCRATCH_TREE_ACTIVE:-} ]]; then
    return 0
  fi
  local src script rel dest rc=0
  src="$(repo_toplevel)"
  script="$(realpath -- "$0")"
  rel="${script#"${src}/"}"
  if [[ ${rel} == "${script}" ]]; then
    printf '%s: %s is not inside the work tree %s\n' "${0##*/}" "${script}" "${src}" >&2
    exit 2
  fi
  dest="$(make_temp --directory)"
  trap 'rm --recursive --force -- "${dest}"' EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  stage_scratch_tree "${src}" "${dest}"
  (
    cd -- "${dest}"
    exec env --unset=GIT_DIR --unset=GIT_WORK_TREE --unset=GIT_INDEX_FILE \
      SCRATCH_TREE_ACTIVE=1 bash "${dest}/${rel}" "$@"
  ) || rc=$?
  exit "${rc}"
}
