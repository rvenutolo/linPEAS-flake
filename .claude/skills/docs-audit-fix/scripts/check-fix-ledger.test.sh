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

# @description Like commit_all, but also stages extra repo-root paths
# (e.g. .gitattributes) that live outside docs/scripts.
function commit_all_special() {
  local -r dir="$1" msg="$2"
  shift 2
  git -C "${dir}" add --all -- docs scripts "$@"
  git -C "${dir}" commit --quiet --message "${msg}"
}

# @description Hash a block exactly as the gate would: via the checker.
function gate_hash() {
  (cd "$1" && "${SCRIPT}" --hash "$2" "$3")
}

# "NAME=value" assignments the next run_case or run_hash_case passes to
# the checker's environment only; each clears it after that one run.
CASE_ENV=()

# @description Run the checker in repo $2 with $2/ledger.json and
# $2/gate.json; assert exit, stderr substring, optional stdout substring.
function run_case() {
  local -r name="$1" dir="$2" expected_exit="$3" expected_stderr="$4"
  local -r expected_stdout="${5:-}"
  local stderr_file stdout_file outcome_file actual_exit=0
  local -a env_args=("${CASE_ENV[@]}")
  CASE_ENV=()
  stderr_file="$(mktemp -p "${SCRATCH}")"
  stdout_file="$(mktemp -p "${SCRATCH}")"
  outcome_file="$(mktemp -p "${SCRATCH}")"
  (cd "${dir}" && env "${env_args[@]}" "${SCRIPT}" ledger.json gate.json) \
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
  local -a env_args=("${CASE_ENV[@]}")
  CASE_ENV=()
  stderr_file="$(mktemp -p "${SCRATCH}")"
  stdout_file="$(mktemp -p "${SCRATCH}")"
  outcome_file="$(mktemp -p "${SCRATCH}")"
  (cd "${dir}" && env "${env_args[@]}" "${SCRIPT}" --hash "$@") \
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

# @description Assert a substring is absent from the last scenario's
# stderr.
function expect_absent() {
  if grep --fixed-strings --quiet -- "$1" "${LAST_STDERR}"; then
    printf 'FAIL: %s — stderr unexpectedly holds %q\n' "${LAST_NAME}" "$1" >&2
    cat -- "${LAST_STDERR}" >&2
    failures=$((failures + 1))
  fi
}

# @description Write a fake `git` into ${SCRATCH}/$1 and print that
# directory, for a run's PATH. Mode $2 is "context" (swap --unified=0
# for --unified=3 and drop --inter-hunk-context=0, so hunks carry
# context lines) or "bad-body" (rewrite the "+Beta paragraph,
# corrected." body line to start with "?"). Everything else goes to the
# real git unchanged.
function make_git_shim() {
  local -r dir="${SCRATCH}/$1" mode="$2"
  local real
  real="$(command -v git)"
  mkdir -p -- "${dir}"
  case "${mode}" in
  context)
    cat >"${dir}/git" <<'EOF'
#!/usr/bin/env bash
a=()
for x in "$@"; do
  case "${x}" in
  --unified=0) a+=(--unified=3) ;;
  --inter-hunk-context=0) ;;
  *) a+=("${x}") ;;
  esac
done
exec @REAL_GIT@ "${a[@]}"
EOF
    ;;
  bad-body)
    cat >"${dir}/git" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" --unified=0 "* ]]; then
  @REAL_GIT@ "$@" | sed 's/^+Beta paragraph, corrected\.$/?Beta paragraph, corrected./'
else
  exec @REAL_GIT@ "$@"
fi
EOF
    ;;
  *) return 1 ;;
  esac
  sed -i "s|@REAL_GIT@|${real}|g" "${dir}/git"
  chmod +x -- "${dir}/git"
  printf '%s\n' "${dir}"
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

# @description Unpaired edits to lines 3 and 9 of a docs/b.md, plus
# unpaired edits on each line $2.. (3, 5 or 7) of a docs/e.md, both
# committed to main first, with an empty ledger and gate. The b.md edits
# are far enough apart that git keeps them as separate hunks under -U0.
function two_file_edit() {
  local -r d="$1"
  shift
  local eline
  git -C "${d}" switch --quiet main
  printf '%s\n' '# B' '' 'Bravo three.' '' 'Bravo five.' '' 'Bravo seven.' \
    '' 'Bravo nine.' >"${d}/docs/b.md"
  printf '%s\n' '# E' '' 'Echo three.' '' 'Echo five.' '' 'Echo seven.' >"${d}/docs/e.md"
  commit_all "${d}" add-b-e
  git -C "${d}" switch --quiet fix
  git -C "${d}" merge --quiet main
  sed -i -e '3s/.*/Bravo WRONG./' -e '9s/.*/Bravo WRONG./' "${d}/docs/b.md"
  for eline in "$@"; do
    sed -i "${eline}s/.*/Echo WRONG./" "${d}/docs/e.md"
  done
  commit_all "${d}" wrong
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
}

# @description Commit file $2 with lines $3.. on main, then merge it into
# fix, so the base holds it and the branch can edit it.
function seed_main() {
  local -r d="$1" file="$2"
  shift 2
  git -C "${d}" switch --quiet main
  printf '%s\n' "$@" >"${d}/${file}"
  commit_all "${d}" "seed ${file}"
  git -C "${d}" switch --quiet fix
  git -C "${d}" merge --quiet main
}

# @description A ledger with pair p1 on $2:$3 and one sibling on $2:$4
# with status $5 (default changed), gated TRUE against the current text.
function sibling_ledger() {
  local -r d="$1" file="$2" plines="$3" slines="$4" status="${5:-changed}"
  jq -n --arg f "${file}" --arg pl "${plines}" --arg sl "${slines}" --arg st "${status}" '{report: "r.md", code_changes: [],
    pairs: [{id: "p1", finding: 1, file: $f, lines: $pl,
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct",
      siblings: [{file: $f, lines: $sl, status: $st}]}]}' >"${d}/ledger.json"
  jq -n --arg h "$(gate_hash "${d}" "${file}" "${plines}")" \
    '{pairs: [{id: "p1", verdict: "TRUE", hash: $h, note: ""}], code_changes: []}' >"${d}/gate.json"
}

function main() {
  local d shim

  d="$(new_repo)"
  beta_fixed "${d}"
  run_case complete "${d}" 0 '' \
    'OK — 1 pairs; 1 hunks covered, 0 reflow-only and 0 generated skipped; 0 code changes; 0 changed, 0 unchanged and 0 removed siblings'

  d="$(new_repo)"
  beta_fixed "${d}"
  printf 'uncommitted\n' >>"${d}/docs/a.md"
  run_case dirty-tree "${d}" 2 'uncommitted changes to tracked files'

  d="$(new_repo)"
  beta_fixed "${d}"
  printf '{not json\n' >"${d}/ledger.json"
  run_case bad-json "${d}" 2 'ledger.json is not valid JSON'

  # jq's exit status reflects only its last input, so a leading stray
  # document raises a jq error on every read that `|| die` never sees;
  # the file must hold exactly one top-level object.
  d="$(new_repo)"
  beta_fixed "${d}"
  { printf '"x"\n' && cat -- "${d}/ledger.json"; } >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case ledger-two-documents "${d}" 2 'ledger.json does not hold exactly one JSON object'

  # An accidental `>>` append leaves two gate objects whose verdicts
  # would merge; only one may be read, so the file is refused.
  d="$(new_repo)"
  beta_fixed "${d}"
  cat -- "${d}/gate.json" >"${d}/g" && cat -- "${d}/g" >>"${d}/gate.json"
  run_case gate-appended-twice "${d}" 2 'gate.json does not hold exactly one JSON object'

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

  # jq test()'s $ matches before a trailing newline, so "1-999999\n"
  # passed the pre-fix rng check; @tsv then emitted the literal
  # newline, and the bash arithmetic error it caused was read by `if`
  # as false, skipping the bound check entirely. A duplicate pair id
  # gives this scenario a second, independent schema finding so its
  # combined output cannot match schema-leading-zero's single line.
  d="$(new_repo)"
  sed -i -e 's/^alpha line two\.$/alpha line WRONG./' \
    -e 's/^Beta paragraph\.$/Beta WRONG./' \
    -e 's/^Gamma paragraph\.$/Gamma WRONG./' "${d}/docs/a.md"
  commit_all "${d}" wrong
  bad_lines=$'1-999999\n'
  jq -n --arg bad "${bad_lines}" '{
    report: "r.md", code_changes: [],
    pairs: [
      { id: "p1", finding: 1, file: "docs/a.md", lines: $bad,
        artifact: [{file: "docs/a.md", lines: "1-1"}], fix_shape: "scope", siblings: [] },
      { id: "p1", finding: 2, file: "docs/a.md", lines: "4-4",
        artifact: [{file: "docs/a.md", lines: "1-1"}], fix_shape: "scope", siblings: [] }
    ]}' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case range-trailing-newline "${d}" 1 'schema: pair id p1 is used more than once'
  also_expect 'schema: pair p1 needs id, file and a <start>-<end> lines'

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
  h="$(gate_hash "${d}" docs/a.md 8-8)"
  printf '{"pairs": [{"id": "p1", "verdict": "TRUE", "hash": "%s", "note": ""}], "code_changes": []}\n' \
    "${h}" >"${d}/gate.json"
  run_case forged-block-after-end "${d}" 1 'uncovered-hunk: docs/a.md:13'

  # A .md file git treats as binary (a NUL byte forces this) now gets a
  # real hunk from list_hunks' --text, so it needs a pair like any other
  # new paragraph rather than a special "must be listed" exemption.
  d="$(new_repo)"
  printf 'binary\000content\n' >"${d}/docs/bin.md"
  commit_all "${d}" binary
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case binary-md "${d}" 1 'uncovered-hunk: docs/bin.md:1'

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

  # diff.external must not replace the real diff with an empty one and
  # hide every hunk. Two filler paragraphs land the edited word at a
  # fresh line (16) no other scenario asserts.
  d="$(new_repo)"
  git -C "${d}" switch --quiet main
  { for i in 1 2; do printf '\nFiller%d paragraph.\n' "${i}"; done; } >>"${d}/docs/a.md"
  commit_all "${d}" fillers
  git -C "${d}" switch --quiet fix
  git -C "${d}" merge --quiet main
  git -C "${d}" config diff.external /bin/true
  sed -i 's/^Filler2 paragraph\.$/Filler2 WRONG./' "${d}/docs/a.md"
  commit_all "${d}" wrong
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case diff-external-configured "${d}" 1 'uncovered-hunk: docs/a.md:16'

  # A "diff=<driver>" attribute plus that driver's textconv must not
  # replace the real diff either. .gitattributes is committed on main
  # before the word edit, so it is part of the merge base and does not
  # itself need a code_changes entry. Three fillers land the edit at
  # line 18.
  d="$(new_repo)"
  git -C "${d}" switch --quiet main
  printf '*.md diff=blank\n' >"${d}/.gitattributes"
  { for i in 1 2 3; do printf '\nFiller%d paragraph.\n' "${i}"; done; } >>"${d}/docs/a.md"
  commit_all_special "${d}" fillers-and-attrs .gitattributes
  git -C "${d}" switch --quiet fix
  git -C "${d}" merge --quiet main
  git -C "${d}" config diff.blank.textconv true
  sed -i 's/^Filler3 paragraph\.$/Filler3 WRONG./' "${d}/docs/a.md"
  commit_all "${d}" wrong
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case textconv-configured "${d}" 1 'uncovered-hunk: docs/a.md:18'

  # A "-diff" .md file listed in code_changes (satisfying the old
  # binary-file exemption) must still need a pair for its actual
  # content, now that list_hunks' --text gives it a real hunk. Four
  # fillers land the edit at line 20.
  d="$(new_repo)"
  git -C "${d}" switch --quiet main
  printf 'docs/a.md -diff\n' >"${d}/.gitattributes"
  { for i in 1 2 3 4; do printf '\nFiller%d paragraph.\n' "${i}"; done; } >>"${d}/docs/a.md"
  commit_all_special "${d}" fillers-and-attrs .gitattributes
  git -C "${d}" switch --quiet fix
  git -C "${d}" merge --quiet main
  sed -i 's/^Filler4 paragraph\.$/Filler4 WRONG./' "${d}/docs/a.md"
  commit_all "${d}" wrong
  printf '{"report": "r.md", "pairs": [], "code_changes": [{"file": "docs/a.md"}]}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case binary-md-listed-in-code-changes "${d}" 1 'uncovered-hunk: docs/a.md:20'

  # diff.noprefix must not desync the "+++ b/<path>" column-7 read this
  # parser relies on. Five fillers land the edit at line 22.
  d="$(new_repo)"
  git -C "${d}" switch --quiet main
  { for i in 1 2 3 4 5; do printf '\nFiller%d paragraph.\n' "${i}"; done; } >>"${d}/docs/a.md"
  commit_all "${d}" fillers
  git -C "${d}" switch --quiet fix
  git -C "${d}" merge --quiet main
  git -C "${d}" config diff.noprefix true
  sed -i 's/^Filler5 paragraph\.$/Filler5 WRONG./' "${d}/docs/a.md"
  commit_all "${d}" wrong
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case noprefix-configured "${d}" 1 'uncovered-hunk: docs/a.md:22'

  # Inserting a second, blank-line-separated copy of Beta right after
  # Beta must not read as a re-wrap: block_span's blank-anchored
  # expansion (for the pure-insertion old side, anchored on the blank
  # line between the two paragraphs) joins them into one span whose
  # collapsed text can equal the new span's, even though real content
  # (a whole duplicated paragraph) was added.
  d="$(new_repo)"
  sed -i '7a\Beta paragraph.\n' "${d}/docs/a.md"
  commit_all "${d}" insert-dup
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case duplicate-paragraph-inserted "${d}" 1 'uncovered-hunk: docs/a.md:8'

  # The same bug in reverse: deleting a second copy of Beta must not
  # read as a re-wrap either. The duplicate is committed to main first
  # so it is part of the merge base the deletion diffs against.
  d="$(new_repo)"
  git -C "${d}" switch --quiet main
  sed -i '7a\Beta paragraph.\n' "${d}/docs/a.md"
  commit_all "${d}" base-with-dup
  git -C "${d}" switch --quiet fix
  git -C "${d}" merge --quiet main
  sed -i '8,9d' "${d}/docs/a.md"
  commit_all "${d}" delete-dup
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case duplicate-paragraph-deleted "${d}" 1 'uncovered-hunk: docs/a.md:7'

  # --hash must reject an end past the file's own line count, the same
  # way the ledger-mode bound checks do.
  d="$(new_repo)"
  run_hash_case hash-past-end "${d}" 2 \
    'bad range: 1-999999 (end must be <= 12 lines)' docs/a.md 1-999999

  # diff.interHunkContext merges b.md's two edits into one hunk carrying
  # context lines. A parser that skips ol+nl body lines then over-skips
  # (each context line is counted in both but printed once) and swallows
  # docs/e.md's header, hiding its unpaired edit. The finding count pins
  # that no context-widened hunk adds spurious findings either.
  d="$(new_repo)"
  two_file_edit "${d}" 3
  git -C "${d}" config diff.interHunkContext 50
  run_case inter-hunk-context-configured "${d}" 1 'uncovered-hunk: docs/e.md:3'
  also_expect 'check-fix-ledger: 3 finding(s) (uncovered-hunk 3)'

  # GIT_DIFF_OPTS overrides --unified=0 from the environment, with the
  # same over-skip. Editing e.md lines 5 and 7 rather than 3 gives this
  # scenario its own findings and count, distinct from
  # inter-hunk-context-configured's.
  d="$(new_repo)"
  two_file_edit "${d}" 5 7
  CASE_ENV=(GIT_DIFF_OPTS=--unified=40)
  run_case git-diff-opts-env "${d}" 1 'uncovered-hunk: docs/e.md:5'
  also_expect 'check-fix-ledger: 4 finding(s) (uncovered-hunk 4)'

  # A "\ No newline at end of file" marker inside a hunk counts against
  # neither side; the file after it must still be parsed.
  d="$(new_repo)"
  git -C "${d}" switch --quiet main
  printf 'Charlie one.\n\nCharlie end.' >"${d}/docs/c.md"
  printf '%s\n' 'Delta one.' '' 'Delta two.' '' 'Delta three.' >"${d}/docs/d.md"
  commit_all "${d}" no-eol
  git -C "${d}" switch --quiet fix
  git -C "${d}" merge --quiet main
  printf 'Charlie one.\n\nCharlie WRONG.' >"${d}/docs/c.md"
  sed -i 's/^Delta three\.$/Delta WRONG./' "${d}/docs/d.md"
  commit_all "${d}" wrong
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case no-newline-marker-mid-diff "${d}" 1 'uncovered-hunk: docs/d.md:5'
  also_expect 'uncovered-hunk: docs/c.md:3'

  # Under a UTF-8 locale bash's [0-9] also matches Arabic-Indic digits,
  # so a range check built on it passes "1-٦٦" and the (( )) bound check
  # after it raises an arithmetic error that `if` reads as false. The
  # range must be rejected by the checker's own message alone.
  d="$(new_repo)"
  CASE_ENV=(LC_ALL=en_US.UTF-8)
  run_hash_case hash-non-ascii-digits "${d}" 2 'bad range: 1-٦٦' docs/a.md '1-٦٦'
  expect_absent 'arithmetic syntax error'
  expect_absent '(start must be'

  # code_changes names are read one per line, so a name holding a
  # newline would add its second line to the listed set: here it would
  # list scripts/tool.sh without an entry that names it. A pair's
  # sibling carries a tab too, so both jq checks show in one output.
  d="$(new_repo)"
  beta_fixed "${d}"
  sed -i 's/^echo line5$/echo line5 changed/' "${d}/scripts/tool.sh"
  commit_all "${d}" code
  jq '.code_changes = [{"file": "x\nscripts/tool.sh"}] |
      .pairs[0].siblings = [{"file": "docs/a\tb.md", "reason": "r"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case file-with-newline "${d}" 1 \
    'schema: code_changes file "x<LF>scripts/tool.sh" holds a newline, tab or CR'
  also_expect 'schema: pair p1 sibling file "docs/a<TAB>b.md" holds a newline, tab or CR'

  # A non-object artifact or sibling entry must be a schema finding, not
  # a jq crash that drops every other schema finding (here the bogus
  # fix_shape) and lets the run pass.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].artifact = ["x"] | .pairs[0].siblings = [1] |
      .pairs[0].fix_shape = "bogus"' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case non-object-artifact "${d}" 1 'schema: pair p1 artifact[0] is not an object'
  also_expect 'schema: pair p1 siblings[0] is not an object'
  also_expect 'enum: pair p1 fix_shape "bogus" is not drop, scope or correct'

  # A non-object pair must not crash the schema check before it reaches
  # the code_changes newline check, whose injected second line would
  # otherwise list the changed scripts/tool.sh.
  d="$(new_repo)"
  sed -i 's/^echo line6$/echo line6 changed/' "${d}/scripts/tool.sh"
  commit_all "${d}" code
  jq -n '{report: "r.md", pairs: ["x", 1],
    code_changes: [{file: "y\nscripts/tool.sh"}]}' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case non-object-pair-hides-newline-file "${d}" 1 'schema: pairs[0] is not an object'
  also_expect 'schema: pairs[1] is not an object'
  also_expect 'schema: code_changes file "y<LF>scripts/tool.sh" holds a newline, tab or CR'

  # A non-object code_changes entry, in the ledger or the gate, is a
  # schema finding (exit 1), never a jq crash (exit 5).
  d="$(new_repo)"
  beta_fixed "${d}"
  sed -i 's/^echo line7$/echo line7 changed/' "${d}/scripts/tool.sh"
  commit_all "${d}" code
  jq '.code_changes = [{"file": "scripts/tool.sh"}, 7]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  jq '.code_changes = [7] | .pairs += ["g"]' \
    "${d}/gate.json" >"${d}/l" && mv -- "${d}/l" "${d}/gate.json"
  run_case non-object-code-change "${d}" 1 'schema: code_changes[1] is not an object'
  also_expect 'schema: gate code_changes[0] is not an object'
  also_expect 'schema: gate pairs[1] is not an object'

  # GIT_LITERAL_PATHSPECS turns the "*.md" pathspec into a literal file
  # name that matches nothing, hiding every Markdown hunk.
  d="$(new_repo)"
  printf 'Foxtrot paragraph.\n' >"${d}/docs/f.md"
  commit_all "${d}" add-f
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  CASE_ENV=(GIT_LITERAL_PATHSPECS=1)
  run_case literal-pathspecs-env "${d}" 1 'uncovered-hunk: docs/f.md:1'

  # A replace ref mapping the changed blob back to the base blob makes
  # git read the old text at HEAD, so the diff shows no hunk.
  d="$(new_repo)"
  git -C "${d}" switch --quiet main
  printf 'Golf paragraph.\n' >"${d}/docs/g.md"
  commit_all "${d}" add-g
  git -C "${d}" switch --quiet fix
  git -C "${d}" merge --quiet main
  printf 'Golf WRONG.\n' >"${d}/docs/g.md"
  commit_all "${d}" wrong
  git -C "${d}" replace "$(git -C "${d}" rev-parse fix:docs/g.md)" \
    "$(git -C "${d}" rev-parse main:docs/g.md)"
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case replace-object "${d}" 1 'uncovered-hunk: docs/g.md:1'

  # Hunks that do carry context lines (forced here by a git shim, since
  # the checker's own flags stop git emitting any) must be consumed by
  # prefix: h.md's edits at 3 and 9 become one hunk with 7 context
  # lines, and skipping only ol+nl body lines would over-skip into
  # docs/k.md's headers and hide its unpaired new paragraph.
  d="$(new_repo)"
  git -C "${d}" switch --quiet main
  printf '%s\n' 'Hotel one.' '' 'Hotel three.' '' 'Hotel five.' '' 'Hotel seven.' \
    '' 'Hotel nine.' >"${d}/docs/h.md"
  commit_all "${d}" add-h
  git -C "${d}" switch --quiet fix
  git -C "${d}" merge --quiet main
  sed -i -e '3s/.*/Hotel WRONG./' -e '9s/.*/Hotel WRONG./' "${d}/docs/h.md"
  printf 'Kilo paragraph.\n' >"${d}/docs/k.md"
  commit_all "${d}" wrong
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  shim="$(make_git_shim ctxshim context)"
  CASE_ENV=("PATH=${shim}:${PATH}")
  run_case context-hunks-shim "${d}" 1 'uncovered-hunk: docs/k.md:1'

  # A hunk body line with a prefix git never emits is a parse error
  # (exit 2), never a silently skipped line.
  d="$(new_repo)"
  beta_fixed "${d}"
  shim="$(make_git_shim badshim bad-body)"
  CASE_ENV=("PATH=${shim}:${PATH}")
  run_case bad-body-line-shim "${d}" 2 \
    'unknown hunk body prefix): ?Beta paragraph, corrected.'
  also_expect 'could not parse the Markdown diff'

  # A sibling marked changed that really changed: pass.
  d="$(new_repo)"
  sed -i -e 's/^Beta paragraph\.$/Beta paragraph, corrected./' \
    -e 's/^Gamma paragraph\.$/Gamma paragraph, corrected./' "${d}/docs/a.md"
  commit_all "${d}" 'beta and gamma'
  jq -n --arg h1 "$(gate_hash "${d}" docs/a.md 6-6)" --arg h2 "$(gate_hash "${d}" docs/a.md 12-12)" \
    '{pairs: [{id: "p1", verdict: "TRUE", hash: $h1, note: ""},
      {id: "p2", verdict: "TRUE", hash: $h2, note: ""}], code_changes: []}' >"${d}/gate.json"
  jq -n '{report: "r.md", code_changes: [], pairs: [
    {id: "p1", finding: 1, file: "docs/a.md", lines: "6-6",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "scope",
      siblings: [{file: "docs/a.md", lines: "12-12", status: "changed"},
        {file: "docs/a.md", lines: "3-4", status: "unchanged", reason: "already scoped"}]},
    {id: "p2", finding: 1, file: "docs/a.md", lines: "12-12",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "scope", siblings: []}]}' \
    >"${d}/ledger.json"
  run_case sibling-changed "${d}" 0 '' \
    'OK — 2 pairs; 2 hunks covered, 0 reflow-only and 0 generated skipped; 0 code changes; 1 changed, 1 unchanged and 0 removed siblings'

  # Unchanged sibling with no reason.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].siblings = [{file: "docs/a.md", lines: "12-12", status: "unchanged"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case sibling-no-reason "${d}" 1 \
    'sibling-reason: pair p1 sibling docs/a.md:12-12 is unchanged with no reason'

  # Negative fixture N4: a sibling claimed changed in a file that has a
  # hunk elsewhere. Guards against checking "changed" at file level.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].siblings = [{file: "docs/a.md", lines: "12-12", status: "changed"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case sibling-not-changed "${d}" 1 \
    'sibling-not-changed: pair p1 sibling docs/a.md:12-12 is marked changed but no hunk touches it'

  # Bad sibling status.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].siblings = [{file: "docs/a.md", lines: "12-12", status: "checked", reason: "x"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case enum-sibling-status "${d}" 1 \
    'enum: pair p1 sibling docs/a.md status "checked" is not changed, unchanged or removed'

  # No verdict for a pair.
  d="$(new_repo)"
  beta_fixed "${d}"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case missing-verdict "${d}" 1 'missing-verdict: pair p1 has no gate verdict'

  # A FALSE verdict blocks.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].verdict = "FALSE" | .pairs[0].note = "artifact says otherwise"' \
    "${d}/gate.json" >"${d}/g" && mv -- "${d}/g" "${d}/gate.json"
  run_case verdict-false "${d}" 1 'verdict: pair p1 is FALSE: artifact says otherwise'

  # Edited after the gate: stale.
  d="$(new_repo)"
  beta_fixed "${d}"
  sed -i 's/^Beta paragraph, corrected\.$/Beta paragraph, corrected again./' "${d}/docs/a.md"
  commit_all "${d}" 'post-gate edit'
  run_case stale-verdict "${d}" 1 'stale-verdict: pair p1 docs/a.md:6-6 changed after the gate read it'

  # Moved, not edited: a line added above Beta (gated separately) shifts
  # it to line 7; the ledger is updated and Beta's old verdict stays
  # current.
  d="$(new_repo)"
  beta_fixed "${d}"
  sed -i '3a Alpha inserted line.' "${d}/docs/a.md"
  commit_all "${d}" 'alpha grows'
  jq '.pairs[0].lines = "7-7" | .pairs += [{id: "p2", finding: 2, file: "docs/a.md", lines: "3-5",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct", siblings: []}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  jq --arg h "$(gate_hash "${d}" docs/a.md 3-5)" '.pairs += [{id: "p2", verdict: "TRUE", hash: $h, note: ""}]' \
    "${d}/gate.json" >"${d}/g" && mv -- "${d}/g" "${d}/gate.json"
  run_case moved-paragraph "${d}" 0 '' \
    'OK — 2 pairs; 2 hunks covered, 0 reflow-only and 0 generated skipped; 0 code changes; 0 changed, 0 unchanged and 0 removed siblings'

  # Negative fixture N3: pair recorded on Alpha's first line only, gated,
  # then Alpha's second line edited. Same block, so the verdict is stale.
  # Guards against hashing the recorded lines instead of the whole block.
  d="$(new_repo)"
  sed -i 's/^Alpha paragraph line one\.$/Alpha paragraph line one, fixed./' "${d}/docs/a.md"
  commit_all "${d}" alpha
  jq -n '{report: "r.md", code_changes: [], pairs: [{id: "p1", finding: 1, file: "docs/a.md", lines: "3-3",
    artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "scope", siblings: []}]}' >"${d}/ledger.json"
  jq -n --arg h "$(gate_hash "${d}" docs/a.md 3-3)" \
    '{pairs: [{id: "p1", verdict: "TRUE", hash: $h, note: ""}], code_changes: []}' >"${d}/gate.json"
  sed -i 's/^alpha line two\.$/alpha line two, edited after the gate./' "${d}/docs/a.md"
  commit_all "${d}" 'post-gate same block'
  run_case stale-same-block "${d}" 1 'stale-verdict: pair p1 docs/a.md:3-3 changed after the gate read it'

  # A listed code change with a gate attack: pass.
  d="$(new_repo)"
  sed -i 's/^echo line5$/echo line5 changed/' "${d}/scripts/tool.sh"
  commit_all "${d}" code
  printf '{"report": "r.md", "pairs": [], "code_changes": [{"file": "scripts/tool.sh", "evidence": "harness"}]}\n' \
    >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": [{"file": "scripts/tool.sh", "attack": "empty input", "result": "exit 2"}]}\n' \
    >"${d}/gate.json"
  run_case code-change-attacked "${d}" 0 '' \
    'OK — 0 pairs; 0 hunks covered, 0 reflow-only and 0 generated skipped; 1 code changes'

  # A listed code change the gate never attacked.
  d="$(new_repo)"
  sed -i 's/^echo line5$/echo line5 changed/' "${d}/scripts/tool.sh"
  commit_all "${d}" code
  printf '{"report": "r.md", "pairs": [], "code_changes": [{"file": "scripts/tool.sh", "evidence": "harness"}]}\n' \
    >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case missing-attack "${d}" 1 'missing-attack: code change scripts/tool.sh has no gate attack and result'

  # Two verdicts for one pair: which one counts would depend on order.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs += [.pairs[0] | .verdict = "FALSE"]' \
    "${d}/gate.json" >"${d}/g" && mv -- "${d}/g" "${d}/gate.json"
  run_case gate-duplicate-id "${d}" 1 'schema: gate verdict id p1 is used more than once'

  # A verdict for a pair the ledger does not hold gates nothing.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs += [{id: "p9", verdict: "TRUE", hash: "0", note: ""}]' \
    "${d}/gate.json" >"${d}/g" && mv -- "${d}/g" "${d}/gate.json"
  run_case gate-unknown-id "${d}" 1 'schema: gate verdict id p9 is not a ledger pair'

  # Negative fixture: a sibling whose only change is a trailing space
  # (a reflow-only hunk, which completeness skips) has not been fixed,
  # so it must not count as changed.
  d="$(new_repo)"
  beta_fixed "${d}"
  sed -i 's/^Gamma paragraph\.$/Gamma paragraph. /' "${d}/docs/a.md"
  commit_all "${d}" 'gamma trailing space'
  jq '.pairs[0].siblings = [{file: "docs/a.md", lines: "12-12", status: "changed"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case sibling-cleared-by-reflow "${d}" 1 \
    'sibling-not-changed: pair p1 sibling docs/a.md:12-12 is marked changed but no covered hunk changes its text'

  # Prose inside a generated block is fixed at its generator, which is a
  # code change; a generated-block hunk does not clear a sibling.
  d="$(new_repo)"
  beta_fixed "${d}"
  sed -i 's/^generated row one$/generated row TWO/' "${d}/docs/a.md"
  commit_all "${d}" 'regenerate'
  jq '.pairs[0].siblings = [{file: "docs/a.md", lines: "9-9", status: "changed"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case sibling-cleared-by-generated "${d}" 1 \
    'sibling-not-changed: pair p1 sibling docs/a.md:9-9 is marked changed but no covered hunk changes its text'

  # A whitespace-only reason is no reason.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].siblings = [{file: "docs/a.md", lines: "3-4", status: "unchanged", reason: " \t "}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case sibling-reason-whitespace "${d}" 1 \
    'sibling-reason: pair p1 sibling docs/a.md:3-4 is unchanged with no reason'

  # A whitespace-only attack is no attack.
  d="$(new_repo)"
  printf 'echo w\n' >"${d}/scripts/w.sh"
  commit_all "${d}" code
  printf '{"report": "r.md", "pairs": [], "code_changes": [{"file": "scripts/w.sh", "evidence": "harness"}]}\n' \
    >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": [{"file": "scripts/w.sh", "attack": "  ", "result": "exit 2"}]}\n' \
    >"${d}/gate.json"
  run_case attack-whitespace "${d}" 1 'missing-attack: code change scripts/w.sh has no gate attack and result'

  # An unchanged sibling must name a file that exists at head.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].siblings = [{file: "docs/nope.md", lines: "1-1", status: "unchanged", reason: "n/a"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case sibling-unchanged-untracked "${d}" 1 \
    'sibling-untracked: pair p1 sibling docs/nope.md is not tracked at the head revision'

  # An OVERREACHES verdict blocks; with no note, no placeholder shows.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].verdict = "OVERREACHES"' "${d}/gate.json" >"${d}/g" && mv -- "${d}/g" "${d}/gate.json"
  run_case verdict-overreaches "${d}" 1 'verdict: pair p1 is OVERREACHES'
  expect_absent 'OVERREACHES:'

  # Verdicts are case-sensitive.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].verdict = "true"' "${d}/gate.json" >"${d}/g" && mv -- "${d}/g" "${d}/gate.json"
  run_case enum-verdict "${d}" 1 'enum: verdict for pair p1 "true" is not TRUE, FALSE or OVERREACHES'

  # A TRUE verdict with no hash never read the paragraph.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq 'del(.pairs[0].hash)' "${d}/gate.json" >"${d}/g" && mv -- "${d}/g" "${d}/gate.json"
  run_case missing-hash "${d}" 1 'missing-hash: pair p1 has a TRUE verdict with no hash'

  # A changed sibling needs a forward <start>-<end> range to match hunks.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].siblings = [{file: "docs/a.md", lines: "12-5", status: "changed"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case sibling-changed-bad-range "${d}" 1 \
    'schema: pair p1 sibling docs/a.md:12-5 is marked changed without a valid <start>-<end> range'

  # Negative fixture: fixing one table row makes the formatter re-align
  # every row. The sibling row's own words did not change, so padding in
  # the same hunk as the real fix must not clear it.
  d="$(new_repo)"
  seed_main "${d}" docs/t.md '# T' '' '| a | b |' '| - | - |' '| x | old |' '| y | wrong |' '| z | ok |'
  printf '%s\n' '# T' '' '| a | b         |' '| - | --------- |' '| x | corrected |' \
    '| y | wrong     |' '| z | ok        |' >"${d}/docs/t.md"
  commit_all "${d}" realign
  sibling_ledger "${d}" docs/t.md 5-5 6-6
  run_case sibling-table-realigned "${d}" 1 \
    'sibling-not-changed: pair p1 sibling docs/t.md:6-6 is marked changed but no covered hunk changes its text'

  # Negative fixture: a trailing space on the sibling item, in the same
  # hunk as the fix to the item above it.
  d="$(new_repo)"
  seed_main "${d}" docs/l.md '- one wrong' '- two wrong'
  printf '%s\n' '- one right' '- two wrong ' >"${d}/docs/l.md"
  commit_all "${d}" 'fix one, pad two'
  sibling_ledger "${d}" docs/l.md 1-1 2-2
  run_case sibling-list-trailing-space "${d}" 1 \
    'sibling-not-changed: pair p1 sibling docs/l.md:2-2 is marked changed but no covered hunk changes its text'

  # Positive control: the sibling item's words change in the same hunk.
  d="$(new_repo)"
  seed_main "${d}" docs/l.md '- one wrong' '- two wrong'
  printf '%s\n' '- one right' '- two right' >"${d}/docs/l.md"
  commit_all "${d}" 'fix both'
  sibling_ledger "${d}" docs/l.md 1-1 2-2
  run_case sibling-list-word-change "${d}" 0 '' \
    'OK — 1 pairs; 1 hunks covered, 0 reflow-only and 0 generated skipped; 0 code changes; 1 changed, 0 unchanged and 0 removed siblings'

  # A changed sibling's range must fall inside its file.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].siblings = [{file: "docs/a.md", lines: "12-99", status: "changed"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case sibling-range-past-end "${d}" 1 \
    'schema: pair p1 sibling docs/a.md:12-99 runs past end of file (12 lines)'

  # A changed sibling's range must sit inside one paragraph; a wide range
  # would be cleared by any hunk it happens to reach.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].siblings = [{file: "docs/a.md", lines: "5-12", status: "changed"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case sibling-spans-blocks "${d}" 1 \
    'schema: pair p1 sibling docs/a.md:5-12 does not lie within one paragraph'

  # A pair's own fix must not clear the pair's own lines as a sibling.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].siblings = [{file: "docs/a.md", lines: "6-6", status: "changed"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case sibling-is-own-pair "${d}" 1 'schema: pair p1 sibling docs/a.md:6-6 overlaps its own pair'

  # A sibling item deleted outright, in the same covered hunk as the
  # pair's fix. Its lines name the HEAD position the text sat at.
  d="$(new_repo)"
  seed_main "${d}" docs/l.md '- one wrong' '- two wrong'
  printf '%s\n' '- one right' >"${d}/docs/l.md"
  commit_all "${d}" 'fix one, drop two'
  sibling_ledger "${d}" docs/l.md 1-1 2-2 removed
  run_case sibling-removed "${d}" 0 '' \
    'OK — 1 pairs; 1 hunks covered, 0 reflow-only and 0 generated skipped; 0 code changes; 0 changed, 0 unchanged and 1 removed siblings'

  # A hunk that only adds lines removed nothing.
  d="$(new_repo)"
  seed_main "${d}" docs/l.md '- one' '- three'
  printf '%s\n' '- one' '- two' '- three' >"${d}/docs/l.md"
  commit_all "${d}" 'add two'
  sibling_ledger "${d}" docs/l.md 2-2 3-3 removed
  run_case sibling-removed-nothing-deleted "${d}" 1 \
    'sibling-not-removed: pair p1 sibling docs/l.md:3-3 is marked removed but no covered hunk deletes text there'

  # The only deleted line reappears re-indented, so no text was removed.
  d="$(new_repo)"
  seed_main "${d}" docs/w.md 'Alpha.' '- two'
  printf '%s\n' 'Alpha.' 'New line.' '  - two' >"${d}/docs/w.md"
  commit_all "${d}" 'insert and indent'
  sibling_ledger "${d}" docs/w.md 2-2 3-3 removed
  run_case sibling-removed-whitespace-only "${d}" 1 \
    'sibling-not-removed: pair p1 sibling docs/w.md:3-3 is marked removed but no covered hunk deletes text there'

  # A removed sibling names a deletion boundary, not a span: a wide range
  # would reach any deleting hunk nearby.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].siblings = [{file: "docs/a.md", lines: "7-13", status: "removed"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case sibling-removed-wide-range "${d}" 1 \
    'schema: pair p1 sibling docs/a.md:7-13 is marked removed with a range wider than a deletion boundary'

  # An edit that replaces one line with one line deletes nothing past its
  # own new line, so the line after it cannot be a removed sibling. The
  # positive case, a line deleted right after the pair's edit in the
  # same hunk, is sibling-removed.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].siblings = [{file: "docs/a.md", lines: "7-7", status: "removed"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case sibling-removed-after-edit "${d}" 1 \
    'sibling-not-removed: pair p1 sibling docs/a.md:7-7 is marked removed but no covered hunk deletes text there'

  # A caller's diff.algorithm must not change the hunks the checker
  # reads. Under myers this edit leaves a hunk whose new side is the blank
  # line 6, which no pair covers; histogram shapes the same change into
  # hunks the pairs do cover. The checker diffs with myers whatever the
  # repository or user configures.
  d="$(new_repo)"
  seed_main "${d}" docs/p.md '' z z y '' x z y '' '' z z
  printf '%s\n' x '' z z '' '' z y '' q '' z z >"${d}/docs/p.md"
  commit_all "${d}" 'reshape p'
  git -C "${d}" config diff.algorithm histogram
  local pl
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  for pl in 1 3 4 7 8 10 12 13; do
    jq --arg l "${pl}-${pl}" '.pairs += [{id: "p\($l)", finding: 1, file: "docs/p.md", lines: $l,
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "drop", siblings: []}]' \
      "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
    jq --arg l "${pl}-${pl}" --arg h "$(gate_hash "${d}" docs/p.md "${pl}-${pl}")" \
      '.pairs += [{id: "p\($l)", verdict: "TRUE", hash: $h, note: ""}]' \
      "${d}/gate.json" >"${d}/g" && mv -- "${d}/g" "${d}/gate.json"
  done
  run_case diff-algorithm-configured "${d}" 1 'uncovered-hunk: docs/p.md:6 changed and no pair covers it'

  harness_assert_verify || failures=$((failures + 1))
  if ((failures > 0)); then
    printf '%d scenario(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf 'all scenarios passed\n'
}

main "$@"
