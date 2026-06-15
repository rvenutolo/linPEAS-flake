#!/usr/bin/env bash
# scripts/check-renovate-markers-matched.sh
#
# @description Lint: every `# renovate: datasource=…` marker in the tree is
# live — some renovate.json customManager scopes the marker's file (a
# managerFilePattern matches the path) and matches a line in it (a matchString
# matches). A customManager that matches none of its declarations freezes the
# dependency silently outside automation coverage; this check fails CI before
# that can happen.
#
# Coverage is file-level, not marker-line-level: marker styles differ (inline,
# where value + `# renovate:` share a line; and above, where the comment sits
# on its own line and the matched value is on the next). Asserting the marker's
# file is consumed by a live manager handles both without a line-adjacency
# heuristic.
#
# Honors RENOVATE_JSON_OVERRIDE (config path) and SCAN_ROOT (tree root) for
# fixture testing. Exits 0 when every marker is live, 1 on any dead marker.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
readonly REPO_ROOT
readonly RENOVATE_JSON="${RENOVATE_JSON_OVERRIDE:-${REPO_ROOT}/renovate.json}"
readonly SCAN_ROOT="${SCAN_ROOT:-${REPO_ROOT}}"

# A functional renovate marker names both a datasource and a depName.
# Requiring depName after datasource keeps real markers in scope while
# excluding label keys (labeler.yml) and prose that merely mentions the marker
# shape (the security docs, the generated scripts reference) — those write the
# datasource token with no following depName. This script is itself excluded
# from the scan below, since its examples do spell out a depName.
readonly MARKER_RE='#\s*renovate:\s*datasource=\S+\s+depName='

if [[ ! -f ${RENOVATE_JSON} ]]; then
  printf 'renovate config not found: %s\n' "${RENOVATE_JSON}" >&2
  exit 1
fi

num_managers="$(jq '.customManagers // [] | length' "${RENOVATE_JSON}")"
readonly num_managers

# @description True if a managerFilePattern of customManager #idx matches the
# given repo-relative path. Renovate filePatterns are slash-delimited regex
# (e.g. /^\.github/.../); strip one leading and one trailing slash, apply as
# PCRE. (All customManagers in this repo use the slash-delimited regex form.)
# @arg $1 customManager index
# @arg $2 repo-relative file path
function file_pattern_matches() {
  local -r idx="$1" rel="$2"
  local pat
  while IFS= read -r pat; do
    [[ -z ${pat} ]] && continue
    pat="${pat#/}"
    pat="${pat%/}"
    if printf '%s' "${rel}" | grep --quiet --perl-regexp -- "${pat}"; then
      return 0
    fi
  done < <(jq -r ".customManagers[${idx}].managerFilePatterns // [] | .[]" "${RENOVATE_JSON}")
  return 1
}

# @description True if any matchString of customManager #idx matches at least
# one line of the given file. Per-line match (grep default) — markers in this
# repo are consumed by single-line matchStrings; multi-line matchStrings
# (e.g. octoscan) belong to files that carry no `# renovate:` marker.
# @arg $1 customManager index
# @arg $2 absolute file path
function match_string_hits_file() {
  local -r idx="$1" file="$2"
  local ms
  while IFS= read -r ms; do
    [[ -z ${ms} ]] && continue
    if grep --quiet --perl-regexp -- "${ms}" "${file}"; then
      return 0
    fi
  done < <(jq -r ".customManagers[${idx}].matchStrings // [] | .[]" "${RENOVATE_JSON}")
  return 1
}

# Build the file list, paths relative to SCAN_ROOT (so they match the
# repo-relative managerFilePatterns).
#   - Live repo (SCAN_ROOT == REPO_ROOT): tracked files, minus the fixture
#     trees (they carry deliberately-dead markers), renovate.json itself
#     (holds the regex strings), and this script (its comments illustrate the
#     marker shape with a depName example).
#   - Fixture scan (SCAN_ROOT overridden): every file under SCAN_ROOT.
declare -a files=()
if [[ ${SCAN_ROOT} == "${REPO_ROOT}" ]]; then
  mapfile -t files < <(
    git -C "${REPO_ROOT}" ls-files -- . \
      ':!:tests/fixtures/**' \
      ':!:renovate.json' \
      ':!:scripts/check-renovate-markers-matched.sh'
  )
else
  abs=""
  while IFS= read -r -d '' abs; do
    files+=("${abs#"${SCAN_ROOT}"/}")
  done < <(find "${SCAN_ROOT}" -type f ! -name renovate.json -print0)
fi

fail=0
for rel in "${files[@]}"; do
  file="${SCAN_ROOT}/${rel}"
  # Only files carrying a real renovate marker need coverage.
  if ! grep --quiet --perl-regexp -- "${MARKER_RE}" "${file}"; then
    continue
  fi
  covered=0
  for ((i = 0; i < num_managers; i++)); do
    if file_pattern_matches "${i}" "${rel}" &&
      match_string_hits_file "${i}" "${file}"; then
      covered=1
      break
    fi
  done
  if [[ ${covered} -eq 0 ]]; then
    while IFS= read -r lineno; do
      printf 'dead renovate marker: %s:%s\n' "${rel}" "${lineno}" >&2
    done < <(grep --line-number --perl-regexp -- "${MARKER_RE}" "${file}" | cut --delimiter=: --fields=1)
    fail=1
  fi
done

exit "${fail}"
