#!/usr/bin/env bash
# tests/refresh-flake-show.test.sh
#
# Round-trip + stale-detection + marker-guard harness for
# scripts/refresh-flake-show.sh. The generator has no output-override
# env and reads docs/reference/flake-outputs.md directly, so the
# mutating assertions back up the real doc and restore it via an EXIT
# trap — a failed assertion never leaves the working tree dirty.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/refresh-flake-show.sh"
readonly DOC="${REPO_ROOT}/docs/reference/flake-outputs.md"

failures=0

# Back up the real doc once; restore on any exit.
BACKUP="$(mktemp)"
cp -- "${DOC}" "${BACKUP}"
readonly BACKUP
function cleanup_test() {
  cp -- "${BACKUP}" "${DOC}"
  rm --force -- "${BACKUP}"
}
trap cleanup_test EXIT

function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

function main() {
  local stderr_file actual_exit

  # Assertion 1: committed doc is fresh — --check exits 0 (round-trip).
  if "${SCRIPT}" --check >/dev/null 2>&1; then
    pass 'committed flake-outputs.md is fresh (--check clean)'
  else
    fail '--check reports committed flake-outputs.md stale'
  fi

  # Assertion 2: --check catches drift. Insert a junk line just before
  # the END marker (inside the managed block) so the committed doc
  # diverges from the freshly generated block; expect exit 1 + message.
  stderr_file="$(mktemp)"
  actual_exit=0
  awk '
    /^<!-- END flake-show -->$/ { print "CORRUPTED-BY-HARNESS" }
    { print }
  ' "${BACKUP}" >"${DOC}"
  "${SCRIPT}" --check >/dev/null 2>"${stderr_file}" || actual_exit=$?
  if [[ ${actual_exit} -eq 1 ]] &&
    grep --fixed-strings --quiet -- 'is stale' "${stderr_file}"; then
    pass 'stale block detected (--check exit 1 + stale message)'
  else
    fail "stale detection: expected exit 1 + 'is stale', got exit ${actual_exit}"
    cat -- "${stderr_file}" >&2
  fi
  cp -- "${BACKUP}" "${DOC}"
  rm --force -- "${stderr_file}"

  # Assertion 3: missing BEGIN marker → exit 1 + marker message. The
  # guard fires before any nix eval.
  stderr_file="$(mktemp)"
  actual_exit=0
  grep --invert-match --fixed-strings -- '<!-- BEGIN flake-show -->' \
    "${BACKUP}" >"${DOC}"
  "${SCRIPT}" --check >/dev/null 2>"${stderr_file}" || actual_exit=$?
  if [[ ${actual_exit} -eq 1 ]] &&
    grep --fixed-strings --quiet -- 'BEGIN marker missing' "${stderr_file}"; then
    pass 'missing BEGIN marker detected (--check exit 1 + marker message)'
  else
    fail "marker guard: expected exit 1 + 'BEGIN marker missing', got exit ${actual_exit}"
    cat -- "${stderr_file}" >&2
  fi
  cp -- "${BACKUP}" "${DOC}"
  rm --force -- "${stderr_file}"

  if [[ ${failures} -gt 0 ]]; then
    printf '%d failure(s)\n' "${failures}" >&2
    exit 1
  fi
  printf 'all passed\n'
}

main "$@"
