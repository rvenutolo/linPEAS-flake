#!/usr/bin/env bash
# scripts/check-lib-source-tool-free.sh
#
# @description Lint: a script under `scripts/` — sourced libraries
# included — never resolves a `source`/`.` library path through a
# command substitution, whether the substitution names `BASH_SOURCE` or
# something else entirely, and `BASH_SOURCE` never appears inside a
# command substitution anywhere else in the file either.
#
# `BASH_SOURCE[0]` is how a script locates its own directory to source a
# shared library. Feeding it through a command substitution needs
# `readlink` and/or `dirname` on PATH, and runs above the guard whose
# whole job is naming a missing tool — a script whose PATH lacks either
# tool dies at exit 127 naming `readlink`, a could-not-run reported
# under neither the exit code this repo reserves for it (2) nor a
# diagnostic naming what was actually absent. That is true wherever the
# substitution sits: directly on the `source` line (`source
# "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/log.sh"`), or one
# line earlier into a variable the `source` line then reads (`_lib_dir="
# $(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"` followed by `source
# "${_lib_dir}/lib/log.sh"`), so this half of the rule scans every line
# of every file rather than source lines alone.
#
# A `source`/`.` line can also shell out to build its path without ever
# naming `BASH_SOURCE` — `source "$(git rev-parse
# --show-toplevel)/scripts/lib/log.sh"` dies exactly the same way under
# a stripped PATH, at whatever tool the substitution invokes. This half
# of the rule is scoped to library source lines: a path under a `lib/`
# directory, or any source line inside a file that is itself under a
# `lib/` directory (a library resolving a sibling). Both are structural
# tests on the line and the file rather than a list of library
# basenames, so a library added later stays covered without the lint
# itself needing an update.
#
# `${BASH_SOURCE[0]%/*}` needs nothing on PATH: the shell performs the
# trim itself, with a `.` fallback for a bare-filename invocation where
# the expansion strips nothing. A bare `${BASH_SOURCE[0]%/*}` with no
# bare-filename fallback stays legal: it is tool-free, and the case it
# misses is an invocation no caller in this repo makes. A comment line
# may still name either banned shape without tripping the check on its
# own documentation.
#
# Breadth is asserted on the same count the source-path half of the rule
# scans: the run reports how many library `source .../lib/*.sh` lines it
# read, and reading none is a broken scan reported as a could-not-run
# rather than a clean tree, whether the scan root holds no shell script
# at all or holds scripts that never source a library.
# `LINT_ALLOW_EMPTY_SCAN=1` suppresses that guard for a scan root that
# deliberately holds none.
#
# Honors SCRIPTS_DIR_OVERRIDE for fixtures. Exits 0 clean, 1 on any
# violation, 2 if the scan set is empty or unreadable.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
install_err_trap

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPTS_DIR="${SCRIPTS_DIR_OVERRIDE:-${REPO_ROOT}/scripts}"

if [[ ! -d ${SCRIPTS_DIR} ]]; then
  printf '%s: scan root %s is not a directory\n' "${0##*/}" "${SCRIPTS_DIR}" >&2
  exit 2
fi

# `**` under globstar also matches zero intervening segments, so one
# pattern covers the root and every subdirectory a library may move into.
shopt -s globstar
files=()
glob_into files "shell scripts under ${SCRIPTS_DIR}" "${SCRIPTS_DIR}/**/*.sh"

readonly SOURCE_RE='^[[:space:]]*(source|\.)[[:space:]]'
readonly COMMENT_LINE_RE='^[[:space:]]*#'
readonly SUBST_RE='\$\('
readonly BASH_SOURCE_RE='BASH_SOURCE'

violations=0
source_lines=0
for file in "${files[@]}"; do
  [[ -f ${file} ]] || continue
  lineno=0
  while IFS= read -r line; do
    lineno=$((lineno + 1))

    is_lib_source_line=0
    if [[ ${line} =~ ${SOURCE_RE} ]] && { [[ ${line} == */lib/* ]] || [[ ${file} == */lib/* ]]; }; then
      source_lines=$((source_lines + 1))
      is_lib_source_line=1
    fi

    # A comment may name either banned shape (this file's own header
    # does) without tripping the check on its own documentation.
    [[ ${line} =~ ${COMMENT_LINE_RE} ]] && continue
    [[ ${line} =~ ${SUBST_RE} ]] || continue

    if [[ ${line} =~ ${BASH_SOURCE_RE} ]]; then
      # shellcheck disable=SC2016 # literal shell syntax quoted for the reader, not a shell expansion
      printf '%s:%d resolves BASH_SOURCE through a command substitution; use "${BASH_SOURCE[0]%%/*}"\n' \
        "${file#"${REPO_ROOT}/"}" "${lineno}" >&2
      violations=$((violations + 1))
    elif ((is_lib_source_line == 1)); then
      printf '%s:%d library source path resolves through a command substitution; spell the directory via parameter expansion instead\n' \
        "${file#"${REPO_ROOT}/"}" "${lineno}" >&2
      violations=$((violations + 1))
    fi
  done <"${file}"
done

if ((source_lines == 0)) && [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
  printf '%s: scanned 0 library source line(s) across %d file(s) under %s — a tree with scripts has source lines; set LINT_ALLOW_EMPTY_SCAN=1 if this root deliberately has none\n' \
    "${0##*/}" "${#files[@]}" "${SCRIPTS_DIR}" >&2
  exit 2
fi

if ((violations > 0)); then
  printf '%s: %d command-substitution site(s) found, of %d library source line(s) scanned\n' \
    "${0##*/}" "${violations}" "${source_lines}" >&2
  exit 1
fi

printf '%s: %d library source line(s) across %d file(s) resolve tool-free\n' \
  "${0##*/}" "${source_lines}" "${#files[@]}"
