#!/usr/bin/env bash
# scripts/check-auto-merge-decline-gate.sh
#
# @description Lint: every workflow run-block that calls `gh pr merge`
# with `--auto` must also carry the decline gate (a `gh pr view --json
# state` query plus a CLOSED|MERGED arm that exits non-zero), so a
# maintainer-closed (declined) or already-merged PR is never silently
# resurrected by an auto-merging update workflow.

# An auto-merging update workflow recreates a per-period branch and
# calls `gh pr merge --auto`. Without inspecting PR state first, a
# re-run in the same period overwrites a PR the maintainer explicitly
# CLOSED (declined) or one already MERGED. The decline gate queries
# `gh pr view --json state` and aborts non-zero on CLOSED|MERGED.
#
# This lint hard-fails if any `--auto` merge run-block lacks that gate,
# foreclosing drift between sibling auto-merge workflows.
#
# Detection is textual, not a full shell parse: a run-block invoking
# `gh pr merge ... --auto` must also contain `--json state` and a
# `CLOSED|MERGED` token co-located with `exit 1`.
#
# See docs/security/workflow-hardening.md.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER for fixtures.
# Exits 0 on full coverage, 1 on any drift, 2 on tooling error.

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/temp.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/temp.sh"

readonly DEFAULT_DIR=".github/workflows"
readonly OVERRIDE="${WORKFLOWS_DIR_OVERRIDE:-}"
readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
readonly DIR="${OVERRIDE:-${DEFAULT_DIR}}"

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 2
fi

failed=0
shopt -s nullglob
for f in "${DIR}"/*.yml "${DIR}"/*.yaml; do
  [[ -f ${f} ]] || continue
  if [[ -n ${FILE_FILTER} && "$(basename "${f}")" != "${FILE_FILTER}" ]]; then
    continue
  fi

  # Capture yq's output into a temp file rather than feeding the loop
  # from `< <(yq ...)`: a process substitution's exit status is not
  # propagated under set -Eeuo pipefail, so a yq parse failure would
  # yield empty input and the file would pass wholesale. NUL-delimited
  # output cannot round-trip through "$(...)" (bash command substitution
  # strips embedded NUL bytes), hence the temp file.
  runs_file="$(make_temp)"
  if ! yq eval -0 '.jobs[].steps[].run // ""' "${f}" >"${runs_file}"; then
    rm --force -- "${runs_file}"
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi

  # Each step run: scalar, NUL-delimited so multi-line blocks stay
  # intact. `// ""` keeps null runs from emitting the literal "null".
  while IFS= read -r -d '' block; do
    [[ -n ${block} ]] || continue
    # Only auto-merge run-blocks are in scope.
    grep -Eq 'gh[[:space:]]+pr[[:space:]]+merge' <<<"${block}" || continue
    grep -Eq -- '--auto' <<<"${block}" || continue
    # Required gate signature, all within this same run-block.
    if grep -q -- '--json state' <<<"${block}" &&
      grep -Eq 'CLOSED\|MERGED' <<<"${block}" &&
      grep -Eq 'exit[[:space:]]+1' <<<"${block}"; then
      continue
    fi
    printf '%s: auto-merge run-block missing CLOSED|MERGED decline gate\n' "${f}" >&2
    failed=$((failed + 1))
  done <"${runs_file}"
  rm --force -- "${runs_file}"
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d auto-merge run-block(s) missing the decline gate\n' "${failed}" >&2
  exit 1
fi
exit 0
