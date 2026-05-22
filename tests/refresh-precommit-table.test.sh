#!/usr/bin/env bash
# tests/refresh-precommit-table.test.sh
#
# Round-trip + drift harness for scripts/refresh-precommit-table.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/refresh-precommit-table.sh"
readonly DOC="${REPO_ROOT}/docs/development/git.md"

failures=0
function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

function main() {
  "${SCRIPT}"
  if "${SCRIPT}" --check; then
    pass '--check passes on freshly generated table'
  else
    fail '--check failed right after generate'
  fi

  if grep --quiet 'commitlint' "${DOC}" &&
    grep --quiet 'nixfmt-rfc-style' "${DOC}" &&
    ! grep --quiet 'commitizen' "${DOC}" &&
    ! grep --quiet 'nixpkgs-fmt' "${DOC}"; then
    pass 'table reflects renamed hooks'
  else
    fail 'table still shows stale hook names'
  fi

  # Use a global (not local) so the EXIT trap can still see it after main
  # returns. Safety net: restore the tracked doc even if set -e fires before
  # the explicit restore below. The explicit cp + rm at the end remain as
  # belt-and-braces for the normal path; this trap only fires if something
  # aborts early or the backup file still exists.
  backup="$(mktemp)"
  cp -- "${DOC}" "${backup}"
  trap '[[ -n "${backup:-}" && -f "${backup}" ]] && { cp -- "${backup}" "${DOC}" 2>/dev/null || true; rm --force -- "${backup}"; }' EXIT
  # Inject drift INSIDE the managed block (a bogus table row right after the
  # BEGIN marker). The generator regenerates the block without it, so --check
  # must detect the mismatch. Drift outside the markers is intentionally NOT
  # the generator's concern.
  local drifted
  drifted="$(mktemp)"
  awk '
    { print }
    /^<!-- BEGIN precommit-table -->$/ { print "| `drift-row` | injected |" }
  ' "${DOC}" >"${drifted}"
  cp -- "${drifted}" "${DOC}"
  rm --force -- "${drifted}"
  local rc=0
  "${SCRIPT}" --check || rc=$?
  cp -- "${backup}" "${DOC}"
  rm --force -- "${backup}"
  if [[ ${rc} -ne 0 ]]; then
    pass '--check fails on in-block drift'
  else
    fail '--check passed despite in-block drift'
  fi

  if [[ ${failures} -gt 0 ]]; then
    printf '%d failure(s)\n' "${failures}" >&2
    exit 1
  fi
  printf 'all passed\n'
}

main "$@"
