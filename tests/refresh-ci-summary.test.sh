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
        if [[ -n "${map_backup:-}" && -f "${map_backup}" ]]; then cp -- "${map_backup}" "${CAT_MAP}" 2>/dev/null || true; rm --force -- "${map_backup}"; fi' EXIT
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

  if [[ ${failures} -gt 0 ]]; then
    printf '%d failure(s)\n' "${failures}" >&2
    exit 1
  fi
  printf 'all passed\n'
}

main "$@"
