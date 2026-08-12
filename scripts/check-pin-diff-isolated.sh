#!/usr/bin/env bash
# scripts/check-pin-diff-isolated.sh
#
# @description Lint: exactly one script under `scripts/` writes to
# `linpeas-pin.json` (bump-linpeas.sh), so the
# `release-on-bump.yml` path-filter trigger contract is
# self-enforcing.

# Lint: assert that `linpeas-pin.json` is the only tracked file ever
# mutated by a script under `scripts/`. The release pipeline trigger
# `release-on-bump.yml` fires on `push` to main with `paths:
# [linpeas-pin.json]`. Any future script that bumps the pin together
# with an unrelated file would create a commit where the pin changed
# but `release-on-bump` may or may not fire depending on the merge-
# commit diff shape. Constraining pin mutation to a single, single-
# target writer makes the trigger contract self-enforcing.
#
# Specifically:
#   1. Exactly one script under `scripts/` writes to `linpeas-pin.json`
#      (today: `bump-linpeas.sh`). Detected by grepping for `mv ...
#      linpeas-pin.json`, `cp ... linpeas-pin.json`, or `> linpeas-pin.json`.
#   2. That single writer is the expected canonical script
#      (`scripts/bump-linpeas.sh`).
#
# Exits 0 on match, 1 on drift. Fixture overrides honored.
# Exits 2 when the scripts directory to scan is absent: with nothing to
# scan there is no writer to count, and reporting that as "no script
# writes the pin" would blame the tree for a missing input.
#
# Env overrides (test-only):
#   SCRIPTS_DIR_OVERRIDE — path to scripts directory to scan

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf '.')"
readonly REPO_ROOT
readonly SCRIPTS_DIR="${SCRIPTS_DIR_OVERRIDE:-${REPO_ROOT}/scripts}"
readonly PIN_FILENAME='linpeas-pin.json'
readonly EXPECTED_WRITER='bump-linpeas.sh'

if [[ ! -d ${SCRIPTS_DIR} ]]; then
  printf 'scripts dir not found: %s\n' "${SCRIPTS_DIR}" >&2
  exit 2
fi

# Two-phase detection. A script is a candidate writer iff:
#   1. It mentions `linpeas-pin.json` somewhere (literally or via a
#      variable assigned to a path containing that filename).
#   2. AND it contains a mutating shell command (`mv`, `cp`, `tee`,
#      or a `>` redirect) on the same line as `linpeas-pin.json`
#      OR as a variable name suggestive of the pin file
#      (`${pin_file}`, `${PIN_FILE}`).
#
# This heuristic catches the canonical atomic-rename pattern
# (`mv -- "${pin_tmp}" "${pin_file}"` with `pin_file=".../linpeas-pin.json"`)
# without false-positiving on read-only scripts (gen-dashboard-data.sh).
readonly LITERAL_REGEX='(^|[[:space:]])(mv|cp|tee)[[:space:]].*linpeas-pin\.json|>[[:space:]]*"?[^"[:space:]]*linpeas-pin\.json'
readonly VAR_REGEX='(^|[[:space:]])(mv|cp|tee)[[:space:]].*\$\{?(pin_file|PIN_FILE|pin_path|PIN_PATH)\}?|>[[:space:]]*"?\$\{?(pin_file|PIN_FILE|pin_path|PIN_PATH)\}?'

# The enumeration is captured rather than piped into `mapfile` through a
# process substitution: a substitution runs in its own subshell, so its
# producer's status never reaches this shell and a grep that could not
# read the tree would look exactly like a tree with no writer in it.
# The trailing `grep --invert-match` legitimately exits 1 when it filters
# every candidate away, so status 1 means "no writers" and only a higher
# status is a could-not-run.
writers_status=0
writers_out="$(
  {
    grep --recursive --files-with-matches --extended-regexp \
      --include='*.sh' "${LITERAL_REGEX}" "${SCRIPTS_DIR}" 2>/dev/null || true
    grep --recursive --files-with-matches --extended-regexp \
      --include='*.sh' "${VAR_REGEX}" "${SCRIPTS_DIR}" 2>/dev/null || true
  } |
    while IFS= read -r line; do
      # Strip the scripts-dir prefix using bash parameter expansion to avoid
      # regex-special characters in the path (e.g. '+' in worktree names)
      # breaking a sed expression.
      printf '%s\n' "${line#"${SCRIPTS_DIR%/}"/}"
    done |
    grep --invert-match --line-regexp 'check-pin-diff-isolated\.sh' |
    sort -u
)" || writers_status=$?
if ((writers_status > 1)); then
  printf 'could not enumerate pin writers under %s\n' "${SCRIPTS_DIR}" >&2
  exit 2
fi

# An empty capture read by `<<<` still yields one empty line, so blank
# entries are dropped here and the count below reflects real writers.
writer_files=()
while IFS= read -r writer; do
  [[ -z ${writer} ]] && continue
  writer_files+=("${writer}")
done <<<"${writers_out}"

if ((${#writer_files[@]} == 0)); then
  printf 'no script under %s writes to %s — expected exactly %s\n' \
    "${SCRIPTS_DIR}" "${PIN_FILENAME}" "${EXPECTED_WRITER}" >&2
  exit 1
fi

if ((${#writer_files[@]} > 1)); then
  printf 'multiple scripts write to %s, only %s is allowed:\n' \
    "${PIN_FILENAME}" "${EXPECTED_WRITER}" >&2
  for f in "${writer_files[@]}"; do
    printf '  - %s\n' "${f}" >&2
  done
  exit 1
fi

if [[ ${writer_files[0]} != "${EXPECTED_WRITER}" ]]; then
  printf 'unexpected writer for %s: got %q, want %q\n' \
    "${PIN_FILENAME}" "${writer_files[0]}" "${EXPECTED_WRITER}" >&2
  exit 1
fi

printf '%s: only writer is %s\n' "${PIN_FILENAME}" "${writer_files[0]}"
