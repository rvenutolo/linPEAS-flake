#!/usr/bin/env bash
# tests/refresh-treefmt-config.test.sh
#
# Round-trip + drift harness for scripts/refresh-treefmt-config.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/refresh-treefmt-config.sh"
readonly DOC="${REPO_ROOT}/docs/reference/treefmt-config.md"

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
    pass '--check passes on freshly generated table'
  else
    fail '--check failed right after generate'
  fi

  if grep --quiet 'nixfmt' "${DOC}" &&
    grep --quiet 'shfmt' "${DOC}"; then
    pass 'formatter table includes nixfmt/shfmt'
  else
    fail 'formatter table missing nixfmt/shfmt'
  fi

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
    /^<!-- BEGIN treefmt-config -->$/ { print "| `drift-formatter` | injected | injected |" }
  ' "${DOC}" >"${drifted}"
  cp -- "${drifted}" "${DOC}"
  rm --force -- "${drifted}"
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

  # A stray .refresh-treefmt-config-*.md left by an interrupted earlier run
  # must be swept by the generator's EXIT-trap cleanup, not left to litter the
  # tree (and risk being staged or tripping markdown lints on itself).
  local stray="${REPO_ROOT}/.refresh-treefmt-config-LEAKTEST.md"
  : >"${stray}"
  "${SCRIPT}" >/dev/null
  if [[ -e ${stray} ]]; then
    rm --force -- "${stray}"
    fail 'generator left a stray .refresh-treefmt-config-*.md temp behind'
  else
    pass 'generator sweeps stray in-repo temps on exit'
  fi

  # Markers the anchored awk splice cannot match (trailing whitespace on both
  # markers) must be rejected by the guard, not silently emitted unchanged.
  # An unanchored guard grep false-greens here; the anchored guard fails
  # closed with a marker-missing message.
  local ws_backup ws_err ws_rc=0
  ws_backup="$(mktemp)"
  ws_err="$(mktemp)"
  cp -- "${DOC}" "${ws_backup}"
  sed -e 's/^<!-- BEGIN treefmt-config -->$/<!-- BEGIN treefmt-config --> /' \
    -e 's/^<!-- END treefmt-config -->$/<!-- END treefmt-config --> /' \
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
