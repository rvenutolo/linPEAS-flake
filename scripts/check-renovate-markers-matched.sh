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
# payload-subject-exempt: renovate.json is maintainer-authored, in-tree config that lands through PR review, not an externally-supplied payload
#
# Honors RENOVATE_JSON_OVERRIDE (config path) and SCAN_ROOT (tree root) for
# fixture testing, and LINT_ALLOW_EMPTY_SCAN=1 to accept an empty scan set.
# Exits 0 when every marker is live, 1 on any dead marker, 2 on a tooling
# error — the config file is absent, the file enumeration failed or came
# back empty, or jq cannot read a customManager's declarations — so no
# verdict about the markers is available and reporting one would blame a
# marker for a config-shape problem.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"

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
  exit 2
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
  local patterns pat

  # Capture jq's output (and exit status) into a variable rather than feeding
  # the loop from `< <(jq ...)`: a process substitution's exit status is not
  # propagated under set -Eeuo pipefail, so a jq failure (managerFilePatterns
  # holding a string instead of an array, say) would yield empty input, the
  # function would answer "no match", and every marked file would be reported
  # as a dead marker — sending the operator to fix markers that are fine.
  if ! patterns="$(jq -r ".customManagers[${idx}].managerFilePatterns // [] | .[]" "${RENOVATE_JSON}")"; then
    printf 'renovate config: could not read customManagers[%s].managerFilePatterns\n' "${idx}" >&2
    exit 2
  fi

  # No patterns at all. Returning here keeps the empty capture from becoming
  # one empty-string iteration of the `<<<` loop below.
  if [[ -z ${patterns} ]]; then
    return 1
  fi

  while IFS= read -r pat; do
    [[ -z ${pat} ]] && continue
    pat="${pat#/}"
    pat="${pat%/}"
    if printf '%s' "${rel}" | grep --quiet --perl-regexp -- "${pat}"; then
      return 0
    fi
  done <<<"${patterns}"
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
  local strings ms

  # Same capture-into-a-variable reason as file_pattern_matches: a process
  # substitution would swallow jq's exit status and turn a config-shape error
  # into a false "dead marker" verdict.
  if ! strings="$(jq -r ".customManagers[${idx}].matchStrings // [] | .[]" "${RENOVATE_JSON}")"; then
    printf 'renovate config: could not read customManagers[%s].matchStrings\n' "${idx}" >&2
    exit 2
  fi

  # No match strings at all. Returning here keeps the empty capture from
  # becoming one empty-string iteration of the `<<<` loop below.
  if [[ -z ${strings} ]]; then
    return 1
  fi

  while IFS= read -r ms; do
    [[ -z ${ms} ]] && continue
    if grep --quiet --perl-regexp -- "${ms}" "${file}"; then
      return 0
    fi
  done <<<"${strings}"
  return 1
}

# Build the file list, paths relative to SCAN_ROOT (so they match the
# repo-relative managerFilePatterns).
#   - Live repo (SCAN_ROOT == REPO_ROOT): tracked files, minus the fixture
#     trees (they carry deliberately-dead markers), renovate.json itself
#     (holds the regex strings), and this script (its comments illustrate the
#     marker shape with a depName example).
#   - Fixture scan (SCAN_ROOT overridden): every file under SCAN_ROOT.
#
# Both branches capture their producer and then assert the scan set is
# non-empty. The same capture-then-check reasoning the two jq helpers
# above carry applies to the enumeration, and the enumeration needs one
# assertion beyond it: `git ls-files` against an unreadable index exits 0
# and prints nothing, so a status check passes while nothing is scanned.
# An empty scan set is the state that makes every marker in the tree look
# absent rather than dead, so it is a tooling fault, not a verdict.
declare -a files=()
if [[ ${SCAN_ROOT} == "${REPO_ROOT}" ]]; then
  # enumerate-exempt: this branch already asserts producer status and
  # scan breadth inline, and the empty-scan diagnostic it prints is the
  # text its harness pins; routing it through the helper would reword
  # that could-not-run message without changing any verdict.
  if ! tracked="$(git -C "${REPO_ROOT}" ls-files -- . \
    ':!:tests/fixtures/**' \
    ':!:renovate.json' \
    ':!:scripts/check-renovate-markers-matched.sh')"; then
    printf '%s: git ls-files failed enumerating the tracked tree\n' "${0##*/}" >&2
    exit 2
  fi
  # An empty capture read by `<<<` still yields one empty line, so blank
  # entries are dropped here and the count below is of real paths.
  while IFS= read -r tracked_rel; do
    [[ -z ${tracked_rel} ]] && continue
    files+=("${tracked_rel}")
  done <<<"${tracked}"
  if ((${#files[@]} == 0)) && [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
    printf '%s: enumerated 0 tracked files via git ls-files — a real tree cannot have an empty scan set; set LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate\n' \
      "${0##*/}" >&2
    exit 2
  fi
else
  # NUL-delimited output cannot survive a shell variable, so the fixture
  # branch captures to a temp file and reads its status from `find`.
  scan_list="$(make_temp)"
  readonly scan_list
  trap 'rm --force -- "${scan_list}"' EXIT
  # enumerate-exempt: same as the branch above — status and breadth are
  # asserted here already, and this branch's own empty-scan diagnostic is
  # pinned by its harness scenario.
  if ! find "${SCAN_ROOT}" -type f ! -name renovate.json -print0 >"${scan_list}"; then
    printf '%s: find failed enumerating %s\n' "${0##*/}" "${SCAN_ROOT}" >&2
    exit 2
  fi
  abs=""
  while IFS= read -r -d '' abs; do
    files+=("${abs#"${SCAN_ROOT}"/}")
  done <"${scan_list}"
  if ((${#files[@]} == 0)) && [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
    printf '%s: enumerated 0 files via find under %s — set LINT_ALLOW_EMPTY_SCAN=1 if this scan root is deliberately empty\n' \
      "${0##*/}" "${SCAN_ROOT}" >&2
    exit 2
  fi
fi

fail=0
live=''
for rel in "${files[@]}"; do
  file="${SCAN_ROOT}/${rel}"
  # Only files carrying a real renovate marker need coverage.
  if ! grep --quiet --perl-regexp -- "${MARKER_RE}" "${file}"; then
    continue
  fi
  # A marker dies two ways, and they call for different edits to
  # renovate.json: no managerFilePattern brings the file into any
  # manager's scope, or a manager does scope it but none of that
  # manager's matchStrings matches a line. Collecting the scoping
  # managers separately from the covering one lets the diagnostic name
  # which of the two happened instead of leaving the operator to bisect
  # the config.
  covering=-1
  scoping=''
  for ((i = 0; i < num_managers; i++)); do
    file_pattern_matches "${i}" "${rel}" || continue
    scoping+="${scoping:+, }customManagers[${i}]"
    if match_string_hits_file "${i}" "${file}"; then
      covering="${i}"
      break
    fi
  done
  if [[ ${covering} -ge 0 ]]; then
    live+="${live:+, }${rel} by customManagers[${covering}]"
    continue
  fi
  if [[ -z ${scoping} ]]; then
    reason='no managerFilePattern scopes this path'
  else
    reason="scoped by ${scoping} but no matchString matches a line"
  fi
  # Captured rather than fed through a process substitution, whose
  # subshell would keep a grep that could not read the file from ever
  # reaching this shell: the marker positions would go silently missing
  # from a diagnostic that exists to name them.
  lineno_status=0
  lineno_rows="$(grep --line-number --perl-regexp -- "${MARKER_RE}" "${file}" |
    cut --delimiter=: --fields=1)" || lineno_status=$?
  if ((lineno_status > 1)); then
    printf '%s: grep failed locating renovate markers in %s\n' \
      "${0##*/}" "${rel}" >&2
    exit 2
  fi
  while IFS= read -r lineno; do
    [[ -z ${lineno} ]] && continue
    printf 'dead renovate marker: %s:%s (%s)\n' "${rel}" "${lineno}" "${reason}" >&2
  done <<<"${lineno_rows}"
  fail=1
done

# A silent exit 0 cannot be told apart from a run that found no markers at
# all — a scan whose file list quietly went empty looks exactly like a
# healthy tree. Name every marked file and the manager that kept it live so
# the pass states what it verified.
if [[ ${fail} -eq 0 ]]; then
  if [[ -z ${live} ]]; then
    printf 'renovate markers: none found\n'
  else
    printf 'renovate markers: all live; matched %s\n' "${live}"
  fi
fi

exit "${fail}"
