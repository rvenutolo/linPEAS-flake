#!/usr/bin/env bash
# scripts/check-payload-shape-scenario.sh
#
# @description Lint: every script that reads an externally-supplied
# payload carries a harness scenario feeding it a malformed payload and
# asserting exit 2. A shape gate (`require_json_payload` or an
# equivalent hand-rolled `die_op` guard) that regresses or was never
# written is invisible to every other lint in this repo, because none of
# them runs the scripts under test — only a scenario that actually drives
# a malformed payload through the gate and checks the exit code proves
# the gate still fires. This lint therefore gates the *scenario's
# existence*, not the gate's source text: grepping a script for
# `require_json_payload` would pass a script that calls it on a path a
# scenario never exercises, and would fail a script whose gate is
# hand-rolled (die_op) but genuinely covered.

# --- Subject predicate (measured, not assumed) --------------------------
#
# A script is a subject when it matches one of four textual arms, each
# added because a narrower predicate was measured against this repo's
# real scripts/*.sh and found to miss a known, already-gated payload
# consumer:
#
#   1. `gh api`                              a literal GitHub API call
#   2. `[A-Z_]+_JSON_OVERRIDE`                a JSON override variable
#   3. `="$(cat)"`                           a bare stdin slurp
#   4. `cat -- ... (flake.lock|LOCK)` or
#      `git show ...:flake.lock`             a scoped lock-content read
#
# Arms 1-2 alone miss check-pre-commit-hooks-sha-parity.sh (no `gh api`
# call; its override is `FLAKE_LOCK_OVERRIDE`, not `*_JSON_OVERRIDE`
# shaped) and check-scorecard-threshold.sh (payload arrives on stdin with
# no override variable at all) — the single highest-severity finding in
# the sweep that established this branch's shape gates. Arms 3-4 close
# both gaps. Arm 4 is scoped to the actual read call rather than to any
# mention of the filename: an earlier "mentions flake.lock anywhere" arm
# was measured and rejected — 6 false positives (scripts that only name
# flake.lock in a comment or a watch list) against 2 true positives.
#
# Declared blind spot: this predicate is textual. A `gh api` call built
# by interpolation (`"$cmd" "$sub" ...` with no literal `gh api`
# substring) and an override variable name built by interpolation
# (`"${prefix}_JSON_OVERRIDE"`) are both invisible to it. No script in
# this repo uses either shape today — this was checked, not assumed —
# but a lint that recognizes only the literal spelling must say so
# rather than imply a reach it does not have.
#
# --- Exemption -----------------------------------------------------------
#
# A script matched by the predicate that reads no externally-supplied
# payload on its verdict path carries an inline
# `# payload-subject-exempt: <rationale>` marker, matching this repo's
# existing `enumerate-exempt` / `glob-exempt` / `exit-code-exempt` /
# `reason-ladder-exempt` convention: the rationale lives beside the code
# it excuses rather than in a hand-maintained doc table that drifts
# silently. A marker on a script the predicate does not match is itself
# reported as a violation — a stale exemption is drift, not a no-op.
#
# --- Scenario requirement -------------------------------------------------
#
# For each non-exempt subject `scripts/<name>.sh`, its paired
# `tests/<name>.test.sh` must carry a scenario whose own text — not the
# script's source — asserts exit 2 against a malformed payload: a line
# passing the exit-code argument this repo's harnesses use (`2` flanked
# by whitespace, the shape `run_scenario 'name' 'fixture' 2 'message'`
# and its variants all share) paired with one of a small vocabulary of
# malformed-payload words (`malformed`, `garbage`, `unparsable`,
# `payload`) on that line, its continuation lines, or the
# contiguous comment block directly above it. A test file that never
# mentions any of those words near an exit-2 assertion is reported as
# lacking the scenario, even if the script's own shape gate is airtight.
#
# Honors SCRIPTS_DIR_OVERRIDE (default: scripts), TESTS_DIR_OVERRIDE
# (default: tests), and LINT_ALLOW_EMPTY_SCAN for a scan root that
# deliberately holds no payload consumer.
# Exit 0 clean, 1 on an uncovered subject or a stale exemption marker,
# 2 when the scripts root cannot be enumerated or matches zero subjects.
#
# payload-subject-exempt: this file's own header documents the four arm patterns and quotes their grep literals, which is enough to match all four arms of its own predicate; it calls no gh api, reads no override variable, and reads no lock file itself

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"

readonly SCRIPTS_DIR="${SCRIPTS_DIR_OVERRIDE:-scripts}"
readonly TESTS_DIR="${TESTS_DIR_OVERRIDE:-tests}"

readonly MARKER_RE='^[[:space:]]*#[[:space:]]*payload-subject-exempt:[[:space:]]*([^[:space:]].*)?$'

# @description True if $1 matches at least one of the four measured
# subject arms. Each arm is tested independently so a future edit to one
# cannot silently widen or narrow another.
function matches_predicate() {
  local -r f="$1"
  grep --quiet 'gh api' "${f}" && return 0
  grep --quiet --extended-regexp '[A-Z_]+_JSON_OVERRIDE' "${f}" && return 0
  grep --quiet --extended-regexp '="\$\(cat\)"' "${f}" && return 0
  grep --quiet --extended-regexp \
    'cat -- .*(flake\.lock|LOCK)|git show.*:flake\.lock' "${f}" && return 0
  return 1
}

# @description Echo the exemption marker's rationale for $1, or nothing
# (and fail) if the script carries no valid marker. A marker whose
# rationale is empty does not count — the same "empty exemption is
# drift, not an exemption" rule this repo's sibling markers already
# enforce.
function exempt_rationale() {
  local -r f="$1"
  local line
  while IFS= read -r line; do
    if [[ ${line} =~ ${MARKER_RE} ]]; then
      [[ -n ${BASH_REMATCH[1]:-} ]] || continue
      printf '%s' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <"${f}"
  return 1
}

# @description True if $1 (a test file) carries a scenario whose own
# text asserts exit 2 against a malformed payload. Reads the file into
# an array once and, for every line shaped like this repo's harnesses'
# exit-2 argument, walks upward through its continuation lines and the
# contiguous comment block above it (the same span
# check-enumerate-helper-required.sh already walks for its own markers),
# then checks that combined window for the malformed-payload vocabulary.
function has_malformed_scenario() {
  local -r test_file="$1"
  [[ -f ${test_file} ]] || return 1

  local -a lines=()
  mapfile -t lines <"${test_file}"
  local -r n=${#lines[@]}
  local i start k window

  for ((i = 0; i < n; i++)); do
    [[ ${lines[i]} == *' 2 '* ]] || continue

    start=${i}
    while ((start > 0)) && [[ ${lines[start - 1]} =~ \\[[:space:]]*$ ]]; do
      start=$((start - 1))
    done
    while ((start > 0)) && [[ ${lines[start - 1]} =~ ^[[:space:]]*# ]]; do
      start=$((start - 1))
    done

    window=""
    for ((k = start; k <= i; k++)); do
      window+="${lines[k]}"$'\n'
    done
    window="${window,,}"

    if [[ ${window} == *malformed* || ${window} == *garbage* ||
      ${window} == *unparsable* || ${window} == *payload* ]]; then
      return 0
    fi
  done
  return 1
}

declare -a all_scripts=()
glob_into all_scripts "shell scripts under ${SCRIPTS_DIR}" "${SCRIPTS_DIR}/*.sh"

failed=0
subjects_scanned=0
scenarios_matched=0
exemptions_applied=0

# Stale-marker rule first: a marker only means something read against the
# predicate it claims to excuse, so every marked script is checked
# regardless of whether it also matched.
for script in "${all_scripts[@]}"; do
  rationale=""
  rationale="$(exempt_rationale "${script}")" || continue
  if ! matches_predicate "${script}"; then
    printf '%s: carries a payload-subject-exempt marker but is not a subject under the payload-subject predicate (marker rationale: %s)\n' \
      "${script}" "${rationale}" >&2
    failed=$((failed + 1))
  fi
done

for script in "${all_scripts[@]}"; do
  matches_predicate "${script}" || continue
  subjects_scanned=$((subjects_scanned + 1))

  if rationale="$(exempt_rationale "${script}")"; then
    exemptions_applied=$((exemptions_applied + 1))
    continue
  fi

  base="${script##*/}"
  test_file="${TESTS_DIR}/${base%.sh}.test.sh"
  if has_malformed_scenario "${test_file}"; then
    scenarios_matched=$((scenarios_matched + 1))
  else
    printf '%s: no scenario asserting exit 2 against a malformed payload found in %s\n' \
      "${script}" "${test_file}" >&2
    failed=$((failed + 1))
  fi
done

# A stale-marker finding is itself a real result and takes priority over
# the empty-scan guard below: zero *matched* subjects with a marker found
# on a non-matching script is still something this run learned, not a
# scan that came back with nothing to say.
if ((failed > 0)); then
  printf '%d payload-shape-scenario violation(s)\n' "${failed}" >&2
  exit 1
fi

if ((subjects_scanned == 0)) && [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
  printf '%s: scanned 0 payload-subject(s) among %d script(s) under %s — set LINT_ALLOW_EMPTY_SCAN=1 if this root deliberately holds no external-payload consumer\n' \
    "${0##*/}" "${#all_scripts[@]}" "${SCRIPTS_DIR}" >&2
  exit 2
fi

printf '%s: ok — %d subject(s) scanned, %d scenario(s) matched, %d exemption(s) applied\n' \
  "${0##*/}" "${subjects_scanned}" "${scenarios_matched}" "${exemptions_applied}"
exit 0
