#!/usr/bin/env bash
# tests/check-changelog-fresh.test.sh
#
# Comparison-logic harness for scripts/check-changelog-fresh.sh. Uses
# CHANGELOG_OVERRIDE + REGEN_OVERRIDE to supply committed/regenerated pairs so
# the released-only diff is exercised without invoking git-cliff or nix.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/check-changelog-fresh.sh"

failures=0
function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# @arg $1 name  @arg $2 committed file  @arg $3 regen file  @arg $4 expected exit
function run_case() {
  local -r name="$1" committed="$2" regen="$3" want="$4"
  local got=0
  CHANGELOG_OVERRIDE="${committed}" REGEN_OVERRIDE="${regen}" \
    "${SCRIPT}" >/dev/null 2>&1 || got=$?
  if [[ ${got} -eq ${want} ]]; then
    pass "${name} (exit ${got})"
  else
    fail "${name} — expected exit ${want}, got ${got}"
  fi
}

function main() {
  local dir
  dir="$(mktemp --directory)"

  cat >"${dir}/fresh.md" <<'EOF'
# Changelog

## Unreleased

### Features

- A pending feature

## [20260715-aaaaaaa] - 2026-07-15

### Features

- Something shipped

## [20260604-bbbbbbb] - 2026-06-08

### Fixes

- Something fixed
EOF

  # Same released sections, different Unreleased content.
  cat >"${dir}/fresh-diff-unreleased.md" <<'EOF'
# Changelog

## Unreleased

### Fixes

- A different pending change

## [20260715-aaaaaaa] - 2026-07-15

### Features

- Something shipped

## [20260604-bbbbbbb] - 2026-06-08

### Fixes

- Something fixed
EOF

  # Missing the newest released section.
  cat >"${dir}/stale.md" <<'EOF'
# Changelog

## Unreleased

### Features

- A pending feature

## [20260604-bbbbbbb] - 2026-06-08

### Fixes

- Something fixed
EOF

  run_case 'fresh: committed released == regen -> exit 0' \
    "${dir}/fresh.md" "${dir}/fresh.md" 0
  run_case 'unreleased-only difference ignored -> exit 0' \
    "${dir}/fresh-diff-unreleased.md" "${dir}/fresh.md" 0
  run_case 'stale: released section missing -> exit 1' \
    "${dir}/stale.md" "${dir}/fresh.md" 1

  rm --recursive --force -- "${dir}"

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
