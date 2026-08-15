#!/usr/bin/env bash
# scripts/check-lib-source-tool-free.sh
#
# @description Lint: every `source .../lib/*.sh` line under `scripts/`
# resolves its library directory by parameter expansion, never through a
# command substitution.
#
# A source line spelled `source "$(dirname "$(readlink -f
# "${BASH_SOURCE[0]}")")/lib/log.sh"` needs `readlink` and `dirname` on
# PATH, and it runs above the guard that exists to name a missing tool.
# A script whose PATH lacks them therefore dies at exit 127 naming
# `readlink` — a could-not-run reported under neither the code the
# convention reserves for it nor a diagnostic that names what was
# actually absent. `${BASH_SOURCE[0]%/*}` needs nothing on PATH.
#
# Only the resolution mechanism is gated. A bare `${BASH_SOURCE[0]%/*}`
# with no bare-filename fallback stays legal: it is tool-free, and the
# case it misses is an invocation no caller in this repo makes.
#
# Breadth is asserted rather than inferred: the run reports how many
# source lines it read, and reading none is a broken scan reported as a
# could-not-run rather than a clean tree. `LINT_ALLOW_EMPTY_SCAN=1`
# suppresses that guard for a scan root that deliberately holds nothing.
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

# A source line, matched before the mechanism is judged, so the scanned
# tally counts the lines the rule is about rather than every line in
# every file.
readonly SOURCE_RE='^[[:space:]]*(source|\.)[[:space:]]'
readonly SUBST_RE='\$\('

violations=0
source_lines=0
for file in "${files[@]}"; do
  [[ -f ${file} ]] || continue
  lineno=0
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    [[ ${line} =~ ${SOURCE_RE} ]] || continue
    # In scope when the line names a path under a `lib/` directory, or
    # when the file doing the sourcing is itself a library resolving a
    # sibling. Both are structural tests. A list of library basenames
    # would stop covering a library added later, and a gate that quietly
    # narrows is the failure this repo's enforcers are built to avoid.
    [[ ${line} == */lib/* || ${file} == */lib/* ]] || continue
    source_lines=$((source_lines + 1))
    if [[ ${line} =~ ${SUBST_RE} ]]; then
      # shellcheck disable=SC2016 # literal shell syntax quoted for the reader, not a shell expansion
      printf '%s:%d resolves its library through a command substitution; use "${BASH_SOURCE[0]%%/*}"\n' \
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
  printf '%s: %d library source line(s) resolve through a command substitution, of %d scanned\n' \
    "${0##*/}" "${violations}" "${source_lines}" >&2
  exit 1
fi

printf '%s: %d library source line(s) across %d file(s) resolve tool-free\n' \
  "${0##*/}" "${source_lines}" "${#files[@]}"
