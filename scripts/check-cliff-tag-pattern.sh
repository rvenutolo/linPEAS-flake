#!/usr/bin/env bash
# scripts/check-cliff-tag-pattern.sh
#
# @description Refuse to build if cliff.toml's tag_pattern drifts from the
# canonical pin-shape regex. One member of the cross-layer parity set;
# docs/architecture/auto-update.md lists every file that carries the
# regex, derived from the tree rather than restated here.
#
# Exits 0 when tag_pattern exactly matches the canonical value.
# Exits 1 on drift (missing key, wrong value).
# Exits 2 when the check could not run: yq absent from PATH, or cliff.toml
# missing. A config that was never read cannot have drifted, so it must not
# borrow the drift code.
#
# Env overrides (test-only):
#   CLIFF_TOML_OVERRIDE — path to a fixture cliff.toml instead of
#     the repo-root cliff.toml

set -Eeuo pipefail
IFS=$'\n\t'

readonly EXPECTED='^[0-9]{8}-[0-9a-f]{7,40}$'

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf '.')"
readonly REPO_ROOT
readonly CLIFF_TOML="${CLIFF_TOML_OVERRIDE:-${REPO_ROOT}/cliff.toml}"

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 2
fi

if [[ ! -f ${CLIFF_TOML} ]]; then
  printf 'cliff.toml not found: %s\n' "${CLIFF_TOML}" >&2
  exit 2
fi

# A cliff.toml that does not parse is a file this check could not read.
# yq exits 1 on it, and an unchecked read would leave the run carrying
# that 1 — the same status a drifted tag pattern produces.
if ! actual="$(yq eval '.git.tag_pattern' "${CLIFF_TOML}")"; then
  printf 'cannot read .git.tag_pattern from %s\n' "${CLIFF_TOML}" >&2
  exit 2
fi

if [[ ${actual} == 'null' ]] || [[ -z ${actual} ]]; then
  printf 'tag_pattern key absent from [git] section in %s\n' "${CLIFF_TOML}" >&2
  exit 1
fi

if [[ ${actual} != "${EXPECTED}" ]]; then
  printf 'tag_pattern drift in %s\n' "${CLIFF_TOML}" >&2
  printf '  got:  %s\n' "${actual}" >&2
  printf '  want: %s\n' "${EXPECTED}" >&2
  exit 1
fi

printf 'cliff.toml tag_pattern matches canonical pin-shape regex\n'
