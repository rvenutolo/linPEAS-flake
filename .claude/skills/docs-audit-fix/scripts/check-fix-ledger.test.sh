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

  # A leading zero must not slip past the range regex into bash's octal
  # arithmetic later. This targets the pair's own lines field rather than
  # the artifact's: an empty artifact list and a non-empty artifact list
  # whose one entry fails the range regex fall through the same jq
  # branch and print the identical schema message, so targeting the
  # artifact here would be indistinguishable from schema-no-artifact.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].lines = "08-99"' "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case schema-leading-zero "${d}" 1 'schema: pair p1 needs id, file and a <start>-<end> lines'

  # A pair's own recorded range must fall inside its file, the same
  # bound check an artifact range gets. A second, valid pair covers the
  # Beta hunk so the only finding is the bad range, not a secondary
  # uncovered-hunk from p1 no longer covering anything.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].lines = "9000-9999" |
      .pairs += [{"id": "p2", "finding": 2, "file": "docs/a.md", "lines": "6-6",
                  "artifact": [{"file": "scripts/tool.sh", "lines": "1-5"}],
                  "fix_shape": "scope", "siblings": []}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case pair-lines-past-end "${d}" 1 \
    'schema: pair p1 docs/a.md:9000-9999 runs past end of file (12 lines)'

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

  # A new BEGIN/END pair introduced only at HEAD must not exempt the
  # prose it wraps: the generated check requires a same-named block to
  # cover the hunk's old side at ${MB} too, and this hunk's old side has
  # no generated block at all.
  d="$(new_repo)"
  sed -i -e '4i\<!-- BEGIN fake -->' -e '4a\<!-- END fake -->' \
    -e 's/^alpha line two\.$/alpha line two, sneaky./' "${d}/docs/a.md"
  commit_all "${d}" wrap
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case markers-added-around-prose "${d}" 1 'uncovered-hunk: docs/a.md:4'

  # An END whose name doesn't match its BEGIN must not close the block;
  # nothing inside counts as generated.
  d="$(new_repo)"
  sed -i -e 's/^<!-- END gen -->$/<!-- END mismatch -->/' \
    -e 's/^generated row one$/generated row two/' "${d}/docs/a.md"
  commit_all "${d}" mismatch
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case mismatched-end-name "${d}" 1 'uncovered-hunk: docs/a.md:9'

  # A content hunk with no pair.
  d="$(new_repo)"
  sed -i 's/^Gamma paragraph\.$/Gamma paragraph, now wrong./' "${d}/docs/a.md"
  commit_all "${d}" gamma
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case uncovered-hunk "${d}" 1 'uncovered-hunk: docs/a.md:12'

  # A diff body line that itself reads "++ b/CHANGELOG.md" must not be
  # mistaken for a "+++" file header and misattribute the hunk after it.
  d="$(new_repo)"
  sed -i -e '4a\++ b/CHANGELOG.md' \
    -e 's/^Gamma paragraph\.$/Gamma paragraph, now wrong./' "${d}/docs/a.md"
  commit_all "${d}" poser
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case body-line-poses-as-header "${d}" 1 'uncovered-hunk: docs/a.md:13'

  # A hunk whose new side spans two HEAD paragraphs (Alpha's edited last
  # line immediately followed by an inserted paragraph, with no context
  # line between them, so it is one hunk) needs a pair for each block; a
  # pair on Alpha only must not cover the inserted paragraph.
  d="$(new_repo)"
  sed -i '4c\alpha line two, changed.\n\nNew paragraph line.' "${d}/docs/a.md"
  commit_all "${d}" twopara
  cat >"${d}/ledger.json" <<'EOF'
{"report": "r.md", "code_changes": [],
  "pairs": [{"id": "p1", "finding": 1, "file": "docs/a.md", "lines": "3-4",
            "artifact": [{"file": "docs/a.md", "lines": "3-4"}],
            "fix_shape": "scope", "siblings": []}]}
EOF
  h="$(gate_hash "${d}" docs/a.md 3-4)"
  printf '{"pairs": [{"id": "p1", "verdict": "TRUE", "hash": "%s", "note": ""}], "code_changes": []}\n' \
    "${h}" >"${d}/gate.json"
  run_case hunk-spans-two-paragraphs "${d}" 1 'uncovered-hunk: docs/a.md:6'

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

  # A hunk whose new side is entirely blank must still need a pair
  # (regression guard for b1a58cce, whose per-block coverage loop left
  # all_covered at its unproven default of 1 when new_side_blocks finds
  # no non-blank run at all). A fresh "Epsilon paragraph." is committed
  # to main first (so it is part of the merge base too, at a line
  # number — 14 — no other scenario asserts), then blanked in place on
  # fix; appending it directly on fix instead would diff as a pure
  # blank-line insertion whose block_span happens to merge backward
  # into Gamma's paragraph and gets misclassified as reflow.
  d="$(new_repo)"
  git -C "${d}" switch --quiet main
  printf '\nEpsilon paragraph.\n' >>"${d}/docs/a.md"
  commit_all "${d}" epsilon-on-main
  git -C "${d}" switch --quiet fix
  git -C "${d}" merge --quiet main
  sed -i '14s/.*//' "${d}/docs/a.md"
  commit_all "${d}" blanked
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case content-replaced-by-blank "${d}" 1 'uncovered-hunk: docs/a.md:14'

  # A pure insertion's old-side position (os, the line BEFORE the
  # insertion) must sit strictly before a generated block's END marker,
  # not on it: inserting a same-named BEGIN/END pair immediately after
  # an existing END must not forge the exemption. An unrelated,
  # separately-paired "Delta paragraph." shifts the forged block off
  # docs/a.md:11 (already asserted by after-end-marker) and, by being
  # blank-line-separated from the generated block on both sides, keeps
  # its own pair's span from expanding across the abutting blocks.
  d="$(new_repo)"
  sed -i '7a\Delta paragraph.\n' "${d}/docs/a.md"
  commit_all "${d}" delta
  sed -i '/^<!-- END gen -->$/a\<!-- BEGIN gen -->\nBrand new prose.\n<!-- END gen -->' "${d}/docs/a.md"
  commit_all "${d}" forge
  cat >"${d}/ledger.json" <<'EOF'
{"report": "r.md", "code_changes": [],
  "pairs": [{"id": "p1", "finding": 1, "file": "docs/a.md", "lines": "8-8",
            "artifact": [{"file": "docs/a.md", "lines": "8-8"}],
            "fix_shape": "scope", "siblings": []}]}
EOF
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case forged-block-after-end "${d}" 1 'uncovered-hunk: docs/a.md:13'

  # A .md file git treats as binary (a NUL byte forces this) produces no
  # "+++"/"@@" headers, so list_hunks never sees it; it must still be
  # required in code_changes rather than silently exempted the way a
  # surviving text .md file is.
  d="$(new_repo)"
  printf 'binary\000content\n' >"${d}/docs/bin.md"
  commit_all "${d}" binary
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case binary-md "${d}" 1 'uncovered-file: docs/bin.md is a binary diff and not listed in code_changes'

  # An arithmetic-overflow range must not wrap past bash's 64-bit
  # signed integers and slip through the >= 1 / <= end bound check.
  # Exercised via --hash so the offending value appears verbatim in the
  # message, rather than through the ledger schema (whose generic "pair
  # p1 needs id, file and a <start>-<end> lines" text would collide with
  # schema-leading-zero).
  d="$(new_repo)"
  run_hash_case range-overflow "${d}" 2 \
    'bad range: 12-18446744073709551628' docs/a.md 12-18446744073709551628

  # A pair's own file must be a blob, the same check an artifact gets.
  # A second, valid pair covers the Beta hunk so the only finding is the
  # directory check, not an incidental uncovered-hunk for Beta.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].file = "docs" |
      .pairs += [{"id": "p2", "finding": 2, "file": "docs/a.md", "lines": "6-6",
                  "artifact": [{"file": "scripts/tool.sh", "lines": "1-5"}],
                  "fix_shape": "scope", "siblings": []}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case pair-file-directory "${d}" 1 'schema: pair p1 file docs is not a file at the head revision'

  harness_assert_verify || failures=$((failures + 1))
  if ((failures > 0)); then
    printf '%d scenario(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf 'all scenarios passed\n'
}

main "$@"
