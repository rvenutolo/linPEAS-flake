#!/usr/bin/env bash
# tests/refresh-precommit-table.test.sh
#
# Round-trip + drift harness for scripts/refresh-precommit-table.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
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
    grep --quiet 'nixfmt' "${DOC}" &&
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
  # The EXIT trap restores the tracked doc and removes the planted leak-test
  # stray. It folds both jobs into one trap because a second `trap ... EXIT`
  # would override this one, leaving the doc unrestored.
  stray="${REPO_ROOT}/.refresh-precommit-deadbeef.md"
  trap '[[ -n "${backup:-}" && -f "${backup}" ]] && { cp -- "${backup}" "${DOC}" 2>/dev/null || true; rm --force -- "${backup}"; }; rm --force -- "${stray:-}"' EXIT
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

  # Leak-cleanup: plant a stray in-repo .md temp (as an interrupted earlier run
  # would leave), run the generator in default mode, and assert the sibling
  # sweep in cleanup() removed both the planted stray and every other
  # .refresh-precommit-*.md in the repo root.
  : >"${stray}"
  "${SCRIPT}"
  if [[ ! -e ${stray} ]]; then
    pass 'sibling sweep removes a planted stray temp'
  else
    fail 'planted stray temp survived a normal run'
  fi
  local leftovers
  leftovers="$(find "${REPO_ROOT}" -maxdepth 1 -name '.refresh-precommit-*.md' -print 2>/dev/null)"
  if [[ -z ${leftovers} ]]; then
    pass 'no .refresh-precommit-*.md temps remain after a normal run'
  else
    fail "stray .refresh-precommit-*.md temps remain: ${leftovers}"
  fi

  # Markers the anchored awk splice cannot match (trailing whitespace on both
  # markers) must be rejected by the guard, not silently emitted unchanged.
  # An unanchored guard grep false-greens here; the anchored guard fails
  # closed with a marker-missing message.
  local ws_backup ws_err ws_rc=0
  ws_backup="$(mktemp)"
  ws_err="$(mktemp)"
  cp -- "${DOC}" "${ws_backup}"
  sed -e 's/^<!-- BEGIN precommit-table -->$/<!-- BEGIN precommit-table --> /' \
    -e 's/^<!-- END precommit-table -->$/<!-- END precommit-table --> /' \
    "${ws_backup}" >"${DOC}"
  "${SCRIPT}" --check >/dev/null 2>"${ws_err}" || ws_rc=$?
  cp -- "${ws_backup}" "${DOC}"
  harness_assert_record 'whitespace-perturbed markers rejected' \
    'marker missing' "${ws_err}"
  if [[ ${ws_rc} -eq 1 ]] &&
    grep --fixed-strings --quiet -- 'marker missing' "${ws_err}"; then
    pass 'whitespace-perturbed markers rejected (fail-closed, not false-green)'
  else
    fail "whitespace marker guard: expected exit 1 + 'marker missing', got exit ${ws_rc}"
    cat -- "${ws_err}" >&2
  fi
  rm --force -- "${ws_backup}" "${ws_err}"

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '%d failure(s)\n' "${failures}" >&2
    exit 1
  fi
  printf 'all passed\n'
}

main "$@"
