#!/usr/bin/env bash
# scripts/mark-docs-audit.sh
#
# @description Record the current commit as the point the semantic docs
# audit was last run against. Writes `.github/docs-audit-state`, which
# `scripts/docs-audit-pressure.sh` uses as its diff base and the monthly
# `docs-audit-reminder` workflow reads through it.
#
# Run this in the final fix PR of an audit cycle — once the audit's
# findings are fixed, not when the audit is dispatched. The marker means
# "everything up to here has been read and its drift resolved", and the
# reminder issue closes on the count it produces; marking at dispatch
# time would close the issue over findings still outstanding.
#
# Writes the file only. Staging and committing stay with the caller, so
# the marker lands in the same reviewed PR as the fixes it vouches for
# rather than as a side effect of running a script.
#
# Honors DOCS_AUDIT_STATE_OVERRIDE (default `.github/docs-audit-state`)
# and REF_OVERRIDE (default `HEAD`) for fixtures.
#
# Exits 0 once the marker is written. Exits 2 when it cannot be written:
# the ref does not resolve to a commit in this history, or the target
# path is not writable. There is no exit 1 — this script records a fact
# rather than judging one, so it has no finding to report.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"

readonly AUDIT_STATE="${DOCS_AUDIT_STATE_OVERRIDE:-.github/docs-audit-state}"
readonly REF="${REF_OVERRIDE:-HEAD}"

function main() {
  local sha
  if ! sha="$(git rev-parse --quiet --verify "${REF}^{commit}" 2>/dev/null)"; then
    printf 'cannot resolve %s to a commit in this history\n' "${REF}" >&2
    exit 2
  fi

  local -r dir="${AUDIT_STATE%/*}"
  if [[ ${dir} != "${AUDIT_STATE}" && ! -d ${dir} ]]; then
    printf 'cannot write %s: %s is not a directory\n' "${AUDIT_STATE}" "${dir}" >&2
    exit 2
  fi

  # Written whole through a temp file and moved into place: a marker
  # truncated by a failed partial write reads as "no LAST_AUDIT_SHA line"
  # to the pressure script, which is a could-not-run the operator would
  # have to diagnose rather than a state anyone chose.
  local tmp
  tmp="$(make_temp)"
  cat >"${tmp}" <<MARKER
# ${AUDIT_STATE}
#
# The commit the semantic docs audit was last run against, once that
# audit's fixes had landed. scripts/docs-audit-pressure.sh diffs CI
# structure from here, so this value is what makes the monthly reminder
# issue's drift count mean "commits nobody has audited yet".
#
# Written by scripts/mark-docs-audit.sh; run \`just docs-audit-done\` in the
# final fix PR of an audit cycle. Do not hand-edit.
LAST_AUDIT_SHA=${sha}
MARKER

  if ! mv -- "${tmp}" "${AUDIT_STATE}"; then
    printf 'cannot write %s\n' "${AUDIT_STATE}" >&2
    exit 2
  fi

  printf 'recorded audit point %s in %s\n' "${sha}" "${AUDIT_STATE}"
}

main "$@"
