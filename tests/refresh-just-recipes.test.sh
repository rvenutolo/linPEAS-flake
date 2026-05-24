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
readonly DOC2="${REPO_ROOT}/docs/reference/just-recipes.md"

failures=0
function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Declared at top-level so the EXIT trap can reference them across function
# boundaries (mirrors tests/refresh-precommit-table.test.sh).
backup=''
backup2=''

function restore_docs() {
  if [[ -n ${backup:-} && -f ${backup} ]]; then
    cp -- "${backup}" "${DOC}" 2>/dev/null || true
    rm --force -- "${backup}"
    backup=''
  fi
  if [[ -n ${backup2:-} && -f ${backup2} ]]; then
    cp -- "${backup2}" "${DOC2}" 2>/dev/null || true
    rm --force -- "${backup2}"
    backup2=''
  fi
}
trap restore_docs EXIT

function main() {
  "${SCRIPT}"
  if "${SCRIPT}" --check; then
    pass '--check passes on freshly generated recipe list'
  else
    fail '--check failed right after generate'
  fi

  if grep --quiet 'just image' "${DOC}" &&
    grep --quiet 'just verify' "${DOC}"; then
    pass 'README recipe list includes image/verify'
  else
    fail 'README recipe list missing image/verify'
  fi

  if grep --quiet 'just image' "${DOC2}" &&
    grep --quiet 'just verify' "${DOC2}"; then
    pass 'reference page recipe list includes image/verify'
  else
    fail 'reference page recipe list missing image/verify'
  fi

  # Drift scenario 1: mutate README block.
  backup="$(mktemp)"
  cp -- "${DOC}" "${backup}"
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
    pass '--check fails on README in-block drift'
  else
    fail '--check passed despite README in-block drift'
  fi

  # Drift scenario 2: mutate the standalone reference page block.
  backup2="$(mktemp)"
  cp -- "${DOC2}" "${backup2}"
  awk '
    { print }
    /^<!-- BEGIN just-recipes -->$/ { print "just drift-recipe   # injected" }
  ' "${DOC2}" >"${DOC2}.tmp"
  mv -- "${DOC2}.tmp" "${DOC2}"
  rc=0
  "${SCRIPT}" --check || rc=$?
  cp -- "${backup2}" "${DOC2}"
  rm --force -- "${backup2}"
  backup2=''
  if [[ ${rc} -ne 0 ]]; then
    pass '--check fails on reference page in-block drift'
  else
    fail '--check passed despite reference page in-block drift'
  fi

  if [[ ${failures} -gt 0 ]]; then
    printf '%d failure(s)\n' "${failures}" >&2
    exit 1
  fi
  printf 'all passed\n'
}

main "$@"
