#!/usr/bin/env bash
# tests/refresh-ci-summary.test.sh
#
# Round-trip + drift harness for scripts/refresh-ci-summary.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/refresh-ci-summary.sh"
readonly DOC="${REPO_ROOT}/README.md"
readonly CAT_MAP="${REPO_ROOT}/docs/_data/ci-check-categories.yml"
readonly REQ_DOC="${REPO_ROOT}/docs/security/required-checks.md"

failures=0
function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Declared at top-level so the EXIT trap can reference it across function
# boundaries (mirrors tests/refresh-just-recipes.test.sh).
backup=''
map_backup=''
req_backup=''

function main() {
  "${SCRIPT}"
  if "${SCRIPT}" --check; then
    pass '--check passes on freshly generated block'
  else
    fail '--check failed right after generate'
  fi

  # Assertion 2: the regenerated block is exhaustive — contains required
  # contexts that were missing from the old curated summary.
  if grep --quiet 'gitleaks' "${DOC}" &&
    grep --quiet 'protect-main-drift-check' "${DOC}"; then
    pass 'block is exhaustive (contains gitleaks and protect-main-drift-check)'
  else
    fail 'block missing exhaustive contexts (gitleaks and/or protect-main-drift-check)'
  fi

  # Assertion 3: in-block drift makes --check exit non-zero.
  backup="$(mktemp)"
  cp -- "${DOC}" "${backup}"
  trap 'if [[ -n "${backup:-}" && -f "${backup}" ]]; then cp -- "${backup}" "${DOC}" 2>/dev/null || true; rm --force -- "${backup}"; fi
        if [[ -n "${map_backup:-}" && -f "${map_backup}" ]]; then cp -- "${map_backup}" "${CAT_MAP}" 2>/dev/null || true; rm --force -- "${map_backup}"; fi
        if [[ -n "${req_backup:-}" && -f "${req_backup}" ]]; then cp -- "${req_backup}" "${REQ_DOC}" 2>/dev/null || true; rm --force -- "${req_backup}"; fi' EXIT
  awk '
    { print }
    /^<!-- BEGIN ci-summary -->$/ { print "- **Drift**: `bogus-context`." }
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

  # Assertion 4: generator fails if a required context has no category-map entry.
  map_backup="$(mktemp)"
  cp -- "${CAT_MAP}" "${map_backup}"
  backup="$(mktemp)"
  cp -- "${DOC}" "${backup}"
  # Remove the gitleaks mapping line from the category map.
  grep --invert-match '^gitleaks:' "${CAT_MAP}" >"${CAT_MAP}.tmp"
  mv -- "${CAT_MAP}.tmp" "${CAT_MAP}"
  local rc2=0
  "${SCRIPT}" --check || rc2=$?
  cp -- "${map_backup}" "${CAT_MAP}"
  rm --force -- "${map_backup}"
  map_backup=''
  cp -- "${backup}" "${DOC}"
  rm --force -- "${backup}"
  backup=''
  if [[ ${rc2} -ne 0 ]]; then
    pass '--check fails when required context has no category-map entry'
  else
    fail '--check passed despite missing category-map entry for gitleaks'
  fi

  # Assertion 5: generator fails when a category-map key has no
  # required-checks entry (divergence direction 2: map key not in
  # required contexts).
  req_backup="$(mktemp)"
  cp -- "${REQ_DOC}" "${req_backup}"
  # Orphan gitleaks: drop its required-checks row, leaving gitleaks: in the map.
  grep --invert-match --extended-regexp '^\| *gitleaks *\|' "${REQ_DOC}" >"${REQ_DOC}.tmp"
  mv -- "${REQ_DOC}.tmp" "${REQ_DOC}"
  local rc3=0
  "${SCRIPT}" --check || rc3=$?
  cp -- "${req_backup}" "${REQ_DOC}"
  rm --force -- "${req_backup}"
  req_backup=''
  if [[ ${rc3} -ne 0 ]]; then
    pass '--check fails when category-map key has no required-checks entry'
  else
    fail '--check passed despite orphaned category-map key gitleaks'
  fi

  # Assertion 6: markers the anchored awk splice cannot match (trailing
  # whitespace on both markers) must be rejected by the guard, not silently
  # emitted unchanged. An unanchored guard grep false-greens here; the
  # anchored guard fails closed with a marker-missing message.
  backup="$(mktemp)"
  ws_err="$(mktemp)"
  cp -- "${DOC}" "${backup}"
  sed -e 's/^<!-- BEGIN ci-summary -->$/<!-- BEGIN ci-summary --> /' \
    -e 's/^<!-- END ci-summary -->$/<!-- END ci-summary --> /' \
    "${backup}" >"${DOC}"
  local rc4=0
  "${SCRIPT}" --check >/dev/null 2>"${ws_err}" || rc4=$?
  cp -- "${backup}" "${DOC}"
  rm --force -- "${backup}"
  backup=''
  if [[ ${rc4} -eq 1 ]] &&
    grep --fixed-strings --quiet -- 'marker missing' "${ws_err}"; then
    pass 'whitespace-perturbed markers rejected (fail-closed, not false-green)'
  else
    fail "whitespace marker guard: expected exit 1 + 'marker missing', got exit ${rc4}"
    cat -- "${ws_err}" >&2
  fi
  rm --force -- "${ws_err}"

  if [[ ${failures} -gt 0 ]]; then
    printf '%d failure(s)\n' "${failures}" >&2
    exit 1
  fi
  printf 'all passed\n'
}

main "$@"
