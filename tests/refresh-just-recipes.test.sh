#!/usr/bin/env bash
# tests/refresh-just-recipes.test.sh
#
# Round-trip + drift harness for scripts/refresh-just-recipes.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/refresh-just-recipes.sh"
readonly DOC="${REPO_ROOT}/README.md"

failures=0
function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Declared at top-level so the EXIT trap can reference it across function
# boundaries (mirrors tests/refresh-precommit-table.test.sh).
backup=''

function main() {
  "${SCRIPT}"
  if "${SCRIPT}" --check; then
    pass '--check passes on freshly generated recipe list'
  else
    fail '--check failed right after generate'
  fi

  if grep --quiet 'just bundle' "${DOC}" &&
    grep --quiet 'just image' "${DOC}" &&
    grep --quiet 'just verify' "${DOC}"; then
    pass 'recipe list includes bundle/image/verify'
  else
    fail 'recipe list missing bundle/image/verify'
  fi

  backup="$(mktemp)"
  cp -- "${DOC}" "${backup}"
  trap 'if [[ -n "${backup:-}" && -f "${backup}" ]]; then cp -- "${backup}" "${DOC}" 2>/dev/null || true; rm --force -- "${backup}"; fi' EXIT
  # Inject drift INSIDE the managed block (a bogus recipe row right after the
  # BEGIN marker). The generator regenerates the block without it, so --check
  # must detect the mismatch.
  awk '
    { print }
    /^# BEGIN just-recipes$/ { print "just drift-recipe   # injected" }
  ' "${DOC}" >"${DOC}.tmp"
  mv -- "${DOC}.tmp" "${DOC}"
  local rc=0
  "${SCRIPT}" --check || rc=$?
  cp -- "${backup}" "${DOC}"
  rm --force -- "${backup}"
  backup=''
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
