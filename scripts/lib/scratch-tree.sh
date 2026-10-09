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
    -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    -c gc.auto=0 -c maintenance.auto=false "$@"
}

# @description Copy the tracked files, as they are on disk, into a new
# directory and commit them there, so the copy is a work tree of its own.
# A tracked file deleted in the source is left out of the copy and out of
# its index. Uncommitted edits to tracked files are carried over; untracked
# and ignored files are not.
# @arg $1 source work tree
# @arg $2 destination directory, which must exist and be empty
# @exitcode 2 the enumeration or the commit failed; a tracked file that
#   exists but cannot be read fails the copy with the exit status of `tar`
function stage_scratch_tree() {
  local -r src="$1" dest="$2"
  local -a tracked=()
  enumerate_into tracked 'tracked files' \
    env --unset=GIT_DIR --unset=GIT_WORK_TREE --unset=GIT_INDEX_FILE \
    git -C "${src}" ls-files -z --cached
  # A path deleted in the source is skipped here, so that a file `tar` cannot
  # read fails the copy instead of vanishing from it.
  local -a present=()
  local path
  for path in "${tracked[@]}"; do
    if [[ -e ${src}/${path} || -L ${src}/${path} ]]; then
      present+=("${path}")
    fi
  done
  printf '%s\0' "${present[@]}" |
    tar --directory="${src}" --null --files-from=- --create |
    tar --directory="${dest}" --extract --same-permissions
  _scratch_git -C "${dest}" init --quiet
  # Automatic maintenance is off so no detached git process can still be
  # writing into .git while the copy is removed: with it on, removal failed
  # with "Directory not empty" in most runs of one harness.
  _scratch_git -C "${dest}" config gc.auto 0
  _scratch_git -C "${dest}" config maintenance.auto false
  printf '%s\0' "${tracked[@]}" |
    _scratch_git -C "${dest}" update-index --add --remove -z --stdin
  _scratch_git -C "${dest}" commit --quiet --no-verify --message scratch
}

# Set by `_scratch_tree_forward`; read by `reexec_in_scratch_tree`.
_scratch_tree_signalled=0

# @description Signal handler of `reexec_in_scratch_tree`: send TERM to the
# process group of every background job and record that a signal arrived.
# The copy run is a session leader, so its group holds everything the
# harness started.
function _scratch_tree_forward() {
  local pid
  _scratch_tree_signalled=1
  for pid in $(jobs -p); do
    kill -TERM -- "-${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
  done
}

# @description Re-run the calling harness inside a scratch copy of the work
# tree it was started from, then exit with the copy run's status. Returns
# without doing anything when the caller is already that copy run. The
# copy is removed on every exit path of the parent. The copy run is a
# session leader, and a SIGTERM, SIGINT or SIGHUP to the parent reaches
# its whole process group, which is waited for before the copy is removed;
# a signal that arrives while the copy is still being built ends the parent
# with status 143 once the build step in flight returns. SIGKILL cannot be
# forwarded and leaves the copy and its run behind.
# Call it after the harness's own preamble and before any statement that
# writes.
# @arg $@ the harness's own arguments, passed through unchanged
# @exitcode 2 the harness is not inside the work tree, `setsid` is missing,
#   or the copy failed
function reexec_in_scratch_tree() {
  local src script rel child rc=0
  src="$(repo_toplevel)"
  # The marker holds the copy's own root, so a `SCRATCH_TREE_ACTIVE`
  # inherited from an unrelated caller does not switch the copy off.
  if [[ ${SCRATCH_TREE_ACTIVE:-} == "${src}" ]]; then
    return 0
  fi
  if ! command -v setsid >/dev/null 2>&1; then
    printf '%s: setsid is not on PATH, so the copy run cannot be signalled as a group\n' "${0##*/}" >&2
    exit 2
  fi
  script="$(realpath -- "$0")"
  rel="${script#"${src}/"}"
  if [[ ${rel} == "${script}" ]]; then
    printf '%s: %s is not inside the work tree %s\n' "${0##*/}" "${script}" "${src}" >&2
    exit 2
  fi
  # Not a local: an errexit exit from inside `stage_scratch_tree` runs the
  # EXIT trap after this function's locals are gone. A copy that cannot be
  # removed is reported but does not replace the harness's verdict: under
  # errexit a failing `rm` in the trap would turn a passing run into exit 1.
  _scratch_tree_dest=''
  _scratch_tree_signalled=0
  trap '[[ -z ${_scratch_tree_dest} ]] || rm --recursive --force -- "${_scratch_tree_dest}" || printf "%s: could not remove the scratch copy %s\n" "${0##*/}" "${_scratch_tree_dest}" >&2' EXIT
  trap _scratch_tree_forward TERM INT HUP
  # Absolute and physical: the copy run changes directory into it, and the
  # marker is compared with the path git reports.
  _scratch_tree_dest="$(make_temp --directory)"
  _scratch_tree_dest="$(realpath -- "${_scratch_tree_dest}")"
  local -r dest="${_scratch_tree_dest}"
  stage_scratch_tree "${src}" "${dest}"
  if ((_scratch_tree_signalled)); then
    exit 143
  fi
  # A background job, so the trap runs while the copy run is in progress:
  # bash defers a trap until a foreground command ends. A background job
  # ignores SIGINT, which is why the handler sends TERM.
  (
    cd -- "${dest}" || exit 2
    exec setsid env --unset=GIT_DIR --unset=GIT_WORK_TREE --unset=GIT_INDEX_FILE \
      "SCRATCH_TREE_ACTIVE=${dest}" bash "${dest}/${rel}" "$@"
  ) &
  child=$!
  wait "${child}" || rc=$?
  while kill -0 "${child}" 2>/dev/null; do
    wait "${child}" || rc=$?
  done
  exit "${rc}"
}
