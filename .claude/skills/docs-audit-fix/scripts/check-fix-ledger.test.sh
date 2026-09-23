#!/usr/bin/env bash
# .claude/skills/docs-audit-fix/scripts/check-fix-ledger.test.sh
#
# Failure-mode harness for check-fix-ledger.sh. Every scenario builds its
# own throwaway git repository, because the checker reads a real diff and a
# checked-in Markdown fixture would be rewritten by the formatter.

set -Eeuo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HERE
REPO_ROOT="$(git -C "${HERE}" rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${HERE}/check-fix-ledger.sh"

failures=0
LAST_STDERR=''
LAST_NAME=''
SCRATCH="$(mktemp -d)"
readonly SCRATCH
trap 'rm -rf -- "${SCRATCH}"' EXIT

# @description Create a scratch repo: base commit on main, then branch fix.
function new_repo() {
  local d
  d="$(mktemp -d -p "${SCRATCH}")"
  git -C "${d}" init --quiet --initial-branch=main
  git -C "${d}" config user.email t@example.invalid
  git -C "${d}" config user.name t
  git -C "${d}" config commit.gpgsign false
  mkdir -p -- "${d}/docs" "${d}/scripts"
  printf '%s\n' '# A' '' 'Alpha paragraph line one.' 'alpha line two.' '' \
    'Beta paragraph.' '' '<!-- BEGIN gen -->' 'generated row one' \
    '<!-- END gen -->' '' 'Gamma paragraph.' >"${d}/docs/a.md"
  {
    printf '#!/usr/bin/env bash\n'
    local i
    for i in $(seq 2 20); do printf 'echo line%d\n' "${i}"; done
  } >"${d}/scripts/tool.sh"
  commit_all "${d}" base
  git -C "${d}" switch --quiet --create fix
  printf '%s\n' "${d}"
}

function commit_all() {
  git -C "$1" add --all -- docs scripts
  git -C "$1" commit --quiet --message "$2"
}

# @description Hash a block exactly as the gate would: via the checker.
function gate_hash() {
  (cd "$1" && "${SCRIPT}" --hash "$2" "$3")
}

# @description Run the checker in repo $2 with $2/ledger.json and
# $2/gate.json; assert exit, stderr substring, optional stdout substring.
function run_case() {
  local -r name="$1" dir="$2" expected_exit="$3" expected_stderr="$4"
  local -r expected_stdout="${5:-}"
  local stderr_file stdout_file outcome_file actual_exit=0
  stderr_file="$(mktemp -p "${SCRATCH}")"
  stdout_file="$(mktemp -p "${SCRATCH}")"
  outcome_file="$(mktemp -p "${SCRATCH}")"
  (cd "${dir}" && "${SCRIPT}" ledger.json gate.json) \
    >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stderr} ]] && ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stdout} ]] && ! grep --fixed-strings --quiet -- "${expected_stdout}" "${stdout_file}"; then
    printf 'FAIL: %s — stdout missing %q\n' "${name}" "${expected_stdout}" >&2
    cat -- "${stdout_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi
  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  if [[ -n ${expected_stdout} ]]; then harness_assert_also "${expected_stdout}"; fi
  LAST_STDERR="${stderr_file}"
  LAST_NAME="${name}"
}

# @description Run the checker directly in --hash mode in repo $2 with
# extra args $5..; assert exit and stderr substring. Mirrors run_case's
# record/assert pattern for the ledger-mode invocation it wraps.
function run_hash_case() {
  local -r name="$1" dir="$2" expected_exit="$3" expected_stderr="$4"
  shift 4
  local stderr_file stdout_file outcome_file actual_exit=0
  stderr_file="$(mktemp -p "${SCRATCH}")"
  stdout_file="$(mktemp -p "${SCRATCH}")"
  outcome_file="$(mktemp -p "${SCRATCH}")"
  (cd "${dir}" && "${SCRIPT}" --hash "$@") \
    >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stderr} ]] && ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi
  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  LAST_STDERR="${stderr_file}"
  LAST_NAME="${name}"
}

# @description Assert one more substring in the last scenario's stderr.
# `harness_assert_also` alone never greps, so this does both.
function also_expect() {
  if ! grep --fixed-strings --quiet -- "$1" "${LAST_STDERR}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${LAST_NAME}" "$1" >&2
    failures=$((failures + 1))
  fi
  harness_assert_also "$1"
}

# @description The ledger for a single correct Beta edit, gated TRUE.
function beta_fixed() {
  local -r d="$1"
  sed -i 's/^Beta paragraph\.$/Beta paragraph, corrected./' "${d}/docs/a.md"
  commit_all "${d}" 'fix beta'
  cat >"${d}/ledger.json" <<'EOF'
{"report": "r.md", "code_changes": [],
  "pairs": [{"id": "p1", "finding": 1, "file": "docs/a.md", "lines": "6-6",
            "artifact": [{"file": "scripts/tool.sh", "lines": "1-5"}],
            "fix_shape": "scope", "siblings": []}]}
EOF
  local h
  h="$(gate_hash "${d}" docs/a.md 6-6)"
  printf '{"pairs": [{"id": "p1", "verdict": "TRUE", "hash": "%s", "note": ""}], "code_changes": []}\n' \
    "${h}" >"${d}/gate.json"
}

function main() {
  local d

  d="$(new_repo)"
  beta_fixed "${d}"
  run_case complete "${d}" 0 '' \
    'OK — 1 pairs; 1 hunks covered, 0 reflow-only and 0 generated skipped; 0 code changes'

  d="$(new_repo)"
  beta_fixed "${d}"
  printf 'uncommitted\n' >>"${d}/docs/a.md"
  run_case dirty-tree "${d}" 2 'uncommitted changes to tracked files'

  d="$(new_repo)"
  beta_fixed "${d}"
  printf '{not json\n' >"${d}/ledger.json"
  run_case bad-json "${d}" 2 'ledger.json is not valid JSON'

  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].artifact = []' "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case schema-no-artifact "${d}" 1 'schema: pair p1 needs a non-empty artifact list'

  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].fix_shape = "sharpen"' "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case enum-fix-shape "${d}" 1 'enum: pair p1 fix_shape "sharpen" is not drop, scope or correct'

  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].artifact[0].lines = "1-999"' "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case artifact-past-end "${d}" 1 'artifact: pair p1 scripts/tool.sh:1-999 runs past end of file (20 lines)'

  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].artifact[0].file = "scripts/nope.sh"' "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case artifact-untracked "${d}" 1 'artifact: pair p1 scripts/nope.sh is not tracked at the head revision'

  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].artifact[0].file = "scripts"' "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case artifact-directory "${d}" 1 'artifact: pair p1 scripts is not a file at the head revision'

  d="$(new_repo)"
  run_hash_case hash-reversed-range "${d}" 2 \
    'bad range: 6-3 (start must be >= 1 and <= end)' docs/a.md 6-3

  # Pure reflow: Alpha's two lines joined, same words. Needs no pair.
  d="$(new_repo)"
  sed -i -e '3{N;s/\n/ /}' "${d}/docs/a.md"
  commit_all "${d}" reflow
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case reflow-only "${d}" 0 '' \
    'OK — 0 pairs; 0 hunks covered, 1 reflow-only and 0 generated skipped; 0 code changes'

  # Negative fixture N1: reflow plus one changed word must still need a
  # pair. Guards against a "reflow" test that compares anything weaker than
  # the collapsed text (word counts, line counts, whitespace-only diffs).
  d="$(new_repo)"
  sed -i -e '3{N;s/\n/ /}' -e 's/line one/line uno/' "${d}/docs/a.md"
  commit_all "${d}" reflow-plus-word
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case reflow-plus-word "${d}" 1 'uncovered-hunk: docs/a.md:3'

  # Inside a generated block: skipped.
  d="$(new_repo)"
  sed -i 's/^generated row one$/generated row two/' "${d}/docs/a.md"
  commit_all "${d}" gen
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case generated-only "${d}" 0 '' \
    'OK — 0 pairs; 0 hunks covered, 0 reflow-only and 1 generated skipped; 0 code changes'

  # Negative fixture N2: a line inserted directly after END is prose, not
  # generated output. Guards against an off-by-one generated range.
  d="$(new_repo)"
  sed -i '10a Inserted after the block.' "${d}/docs/a.md"
  commit_all "${d}" after-end
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case after-end-marker "${d}" 1 'uncovered-hunk: docs/a.md:11'

  # A content hunk with no pair.
  d="$(new_repo)"
  sed -i 's/^Gamma paragraph\.$/Gamma paragraph, now wrong./' "${d}/docs/a.md"
  commit_all "${d}" gamma
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case uncovered-hunk "${d}" 1 'uncovered-hunk: docs/a.md:12'

  # A changed non-Markdown file not listed as a code change.
  d="$(new_repo)"
  sed -i 's/^echo line5$/echo line5 changed/' "${d}/scripts/tool.sh"
  commit_all "${d}" code
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case uncovered-file "${d}" 1 'uncovered-file: scripts/tool.sh is changed but not listed in code_changes'

  # A deleted Markdown file has no paragraph to pair; it must be listed.
  d="$(new_repo)"
  git -C "${d}" rm --quiet -- docs/a.md
  git -C "${d}" commit --quiet --message delete
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case deleted-md "${d}" 1 'uncovered-file: docs/a.md is changed but not listed in code_changes'

  # A space in a filename must not break hunk attribution.
  d="$(new_repo)"
  printf 'Spaced paragraph.\n' >"${d}/docs/b c.md"
  commit_all "${d}" spaced
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case space-in-name "${d}" 1 'uncovered-hunk: docs/b c.md:1'

  harness_assert_verify || failures=$((failures + 1))
  if ((failures > 0)); then
    printf '%d scenario(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf 'all scenarios passed\n'
}

main "$@"
