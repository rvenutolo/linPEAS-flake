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
LAST_STDOUT=''
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
  LAST_STDOUT="${stdout_file}"
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
# `harness_assert_also` checks presence only at `harness_assert_verify`,
# against every stream the record holds; this pins it to stderr.
function also_expect() {
  if ! grep --fixed-strings --quiet -- "$1" "${LAST_STDERR}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${LAST_NAME}" "$1" >&2
    failures=$((failures + 1))
  fi
  harness_assert_also "$1"
}

# @description Assert one more substring in the last scenario's stdout.
function also_expect_stdout() {
  if ! grep --fixed-strings --quiet -- "$1" "${LAST_STDOUT}"; then
    printf 'FAIL: %s — stdout missing %q\n' "${LAST_NAME}" "$1" >&2
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

# @description Assert a substring is absent from the last scenario's
# stdout.
function expect_absent_stdout() {
  if grep --fixed-strings --quiet -- "$1" "${LAST_STDOUT}"; then
    printf 'FAIL: %s — stdout unexpectedly holds %q\n' "${LAST_NAME}" "$1" >&2
    cat -- "${LAST_STDOUT}" >&2
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
            "fix_shape": "scope", "sweep": ["Beta paragraph."],
            "anchor": "Beta paragraph, corrected", "siblings": []}]}
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

# @description A ledger with pair p1 on $2:$3 anchored on $4 and one
# sibling on $2:$5 with status $6 (default changed) and sweep terms $7 (a
# JSON array, default none), gated TRUE against the current text.
function sibling_ledger() {
  local -r d="$1" file="$2" plines="$3" anchor="$4" slines="$5" status="${6:-changed}" sweep="${7:-null}"
  jq -n --arg f "${file}" --arg pl "${plines}" --arg an "${anchor}" --arg sl "${slines}" --arg st "${status}" \
    --argjson sw "${sweep}" '{report: "r.md", code_changes: [],
    pairs: [{id: "p1", finding: 1, file: $f, lines: $pl, anchor: $an,
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct",
      siblings: [{file: $f, lines: $sl, status: $st}]} + (if $sw == null then {} else {sweep: $sw} end)]}' >"${d}/ledger.json"
  jq -n --arg h "$(gate_hash "${d}" "${file}" "${plines}")" \
    '{pairs: [{id: "p1", verdict: "TRUE", hash: $h, note: ""}], code_changes: []}' >"${d}/gate.json"
}

# @description Gate every pair of $1/ledger.json TRUE at its current
# hash, and attack every code change at the blob it holds at HEAD (or
# "deleted").
function gate_all() {
  local -r d="$1"
  local id file lines blob
  local pairs='[]' changes='[]'
  while IFS=$'\t' read -r id file lines; do
    [[ -n ${id} ]] || continue
    pairs="$(jq --arg id "${id}" --arg h "$(gate_hash "${d}" "${file}" "${lines}")" \
      '. + [{id: $id, verdict: "TRUE", hash: $h, note: ""}]' <<<"${pairs}")"
  done < <(jq --raw-output '.pairs[] | [.id, .file, .lines] | @tsv' "${d}/ledger.json")
  while IFS= read -r file; do
    [[ -n ${file} ]] || continue
    blob="$(git -C "${d}" rev-parse --verify --quiet "HEAD:${file}")" || blob=deleted
    changes="$(jq --arg f "${file}" --arg b "${blob}" \
      '. + [{file: $f, blob: $b, attack: "constructed input", result: "fails"}]' <<<"${changes}")"
  done < <(jq --raw-output '.code_changes[].file' "${d}/ledger.json")
  jq -n --argjson p "${pairs}" --argjson c "${changes}" '{pairs: $p, code_changes: $c}' >"${d}/gate.json"
}

# @description The Beta fix of beta_fixed (and its anchor) with pair p1's sweep set to $2
# (a JSON value, or the word "omit" to drop the field) and its siblings
# to $3 (a JSON array, default []), plus code_changes files $4.. listed
# with evidence; gated with gate_all.
function sweep_case() {
  local -r d="$1" sweep="$2" siblings="${3:-[]}"
  shift 2
  if (($# > 0)); then shift; fi
  local changes='[]' f
  for f in "$@"; do
    changes="$(jq --arg f "${f}" '. + [{file: $f, evidence: "harness"}]' <<<"${changes}")"
  done
  jq -n --arg sw "${sweep}" --argjson sib "${siblings}" --argjson c "${changes}" \
    '{report: "r.md", code_changes: $c,
      pairs: [{id: "p1", finding: 1, file: "docs/a.md", lines: "6-6",
        anchor: "Beta paragraph, corrected",
        artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct",
        siblings: $sib} + (if $sw == "omit" then {} else {sweep: ($sw | fromjson)} end)]}' \
    >"${d}/ledger.json"
  gate_all "${d}"
}

# @description Run the checker in --sweep mode in repo $2 with terms
# $6..; assert exit, a stderr substring and a stdout substring ($5).
function run_sweep_case() {
  local -r name="$1" dir="$2" expected_exit="$3" expected_stderr="$4" expected_stdout="$5"
  shift 5
  local stderr_file stdout_file outcome_file actual_exit=0
  stderr_file="$(mktemp -p "${SCRATCH}")"
  stdout_file="$(mktemp -p "${SCRATCH}")"
  outcome_file="$(mktemp -p "${SCRATCH}")"
  (cd "${dir}" && "${SCRIPT}" "$@") >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
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
  LAST_STDOUT="${stdout_file}"
  LAST_NAME="${name}"
}

# @description Write each "path" "content" pair after $1 into repo $1
# on main (content gets a trailing newline), commit them, and merge
# main into fix, so the merge base holds them.
function seed_files() {
  local -r d="$1"
  shift
  local -a paths=()
  git -C "${d}" switch --quiet main
  while (($# >= 2)); do
    mkdir -p -- "$(dirname -- "${d}/$1")"
    printf '%s\n' "$2" >"${d}/$1"
    paths+=("$1")
    shift 2
  done
  git -C "${d}" add -- "${paths[@]}"
  git -C "${d}" commit --quiet --message seed
  git -C "${d}" switch --quiet fix
  git -C "${d}" merge --quiet main
}

function main() {
  local d shim

  d="$(new_repo)"
  beta_fixed "${d}"
  run_case complete "${d}" 0 '' \
    'OK — 1 pairs; 1 hunks covered, 0 reflow-only and 0 generated skipped; 0 code changes; 0 changed, 0 unchanged and 0 removed siblings; 1 sweep terms, 1 hits cleared'
  # A ledger citing no command keeps the OK line it always had.
  expect_absent_stdout 'command artifacts'

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

  # A key repeated inside one object resolves to its last value, so an
  # earlier FALSE verdict would be shadowed by a later TRUE one. The file
  # is refused, naming the repeated key.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq --raw-output '.pairs[0].hash' "${d}/gate.json" >"${d}/h"
  printf '{"pairs": [{"id": "p1", "verdict": "FALSE", "note": "artifact disagrees", "verdict": "TRUE", "hash": "%s", "note": ""}], "code_changes": []}\n' \
    "$(cat -- "${d}/h")" >"${d}/gate.json"
  run_case gate-duplicate-key "${d}" 2 'gate.json repeats key .pairs[0].verdict'

  # A repeated key whose value is a container is caught too: the second
  # siblings list replaces the first, whose changed sibling no hunk
  # touches.
  d="$(new_repo)"
  beta_fixed "${d}"
  cat >"${d}/ledger.json" <<'EOF'
{"report": "r.md", "code_changes": [],
  "pairs": [{"id": "p1", "finding": 1, "file": "docs/a.md", "lines": "6-6",
            "artifact": [{"file": "scripts/tool.sh", "lines": "1-5"}],
            "fix_shape": "scope",
            "siblings": [{"file": "docs/a.md", "lines": "12-12", "status": "changed"}],
            "siblings": []}]}
EOF
  run_case ledger-duplicate-key "${d}" 2 'ledger.json repeats key .pairs[0].siblings'

  # The second value need share no path with the first: a command
  # artifact list replacing a file artifact list is caught at the key
  # that holds them both, not at any leaf.
  d="$(new_repo)"
  beta_fixed "${d}"
  cat >"${d}/ledger.json" <<'EOF'
{"report": "r.md", "code_changes": [],
  "pairs": [{"id": "p1", "finding": 1, "file": "docs/a.md", "lines": "6-6",
            "artifact": [{"file": "scripts/tool.sh", "lines": "1-5"}],
            "artifact": [{"command": "git config --local --get x", "observed": "exit 1"}],
            "fix_shape": "scope", "siblings": []}]}
EOF
  run_case ledger-duplicate-key-new-children "${d}" 2 'ledger.json repeats key .pairs[0].artifact'

  # A key that is not a plain identifier is shown JSON-quoted, so "a.b"
  # does not read as a nested b and a newline cannot split the message.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq --compact-output '.pairs[0]["x.y\nz"] = 1' "${d}/ledger.json" |
    sed 's/"x\.y\\nz":1/"x.y\\nz":1,"x.y\\nz":2/' >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case ledger-duplicate-key-quoted "${d}" 2 'ledger.json repeats key .pairs[0]["x.y\nz"]'

  # A trailing newline must not pass the identifier test: jq's $ matches
  # before it, so "abc\n" would read as a plain abc and split the line.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq --compact-output '.pairs[0]["abc\n"] = 1' "${d}/ledger.json" |
    sed 's/"abc\\n":1/"abc\\n":1,"abc\\n":2/' >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case ledger-duplicate-key-trailing-newline "${d}" 2 'ledger.json repeats key .pairs[0]["abc\n"]'

  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].artifact = []' "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case schema-no-artifact "${d}" 1 'schema: pair p1 needs a non-empty artifact list'

  # A fact that lives outside the tree is cited as the command that shows
  # it and what it printed. The checker validates the entry's shape and
  # never runs the command: the payload here only creates a marker file,
  # and the marker must not exist after the run.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].artifact = [{command: "touch RAN", observed: "exit 1, no output"}]
    | .pairs[0].siblings = [{file: "docs/a.md", lines: "3-4", status: "unchanged", reason: "true as written"},
      {file: "docs/a.md", lines: "12-12", status: "unchanged", reason: "true as written"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case artifact-command "${d}" 0 '' \
    'OK — 1 pairs; 1 hunks covered, 0 reflow-only and 0 generated skipped; 0 code changes; 0 changed, 2 unchanged and 0 removed siblings; 1 command artifacts, shape-checked only'
  if [[ -e ${d}/RAN ]]; then
    printf 'FAIL: %s — the checker ran an artifact command\n' "${LAST_NAME}" >&2
    failures=$((failures + 1))
  fi

  # A command entry beside a file entry leaves the file entry's checks in
  # force: its range still has to fit its file, and the command entry is
  # not read as a file.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].artifact = [{command: "git config --local --get x", observed: "exit 1"},
      {file: "scripts/tool.sh", lines: "1-99"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case artifact-command-beside-file "${d}" 1 \
    'artifact: pair p1 scripts/tool.sh:1-99 runs past end of file (20 lines)'
  expect_absent 'is not tracked'

  # A malformed file entry is still a schema finding when a well-formed
  # command entry sits beside it.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].artifact = [{command: "git config --local --get x", observed: "exit 1"},
      {file: "scripts/tool.sh"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case artifact-command-beside-bad-file "${d}" 1 \
    'schema: pair p1 artifact[1] needs a file and a <start>-<end> lines'

  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].artifact = [{command: "git config --local --get x"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case artifact-command-no-observed "${d}" 1 \
    'schema: pair p1 artifact[0] needs a non-blank observed string, got null'

  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].artifact = [{command: "git config --local --get x", observed: "   "}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case artifact-command-blank-observed "${d}" 1 \
    'schema: pair p1 artifact[0] needs a non-blank observed string, got "   "'

  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].artifact = [{command: "", observed: "exit 1"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case artifact-command-empty "${d}" 1 \
    'schema: pair p1 artifact[0] needs a non-blank command string, got ""'

  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].artifact = [{command: ["git", "config"], observed: "exit 1"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case artifact-command-not-string "${d}" 1 \
    'schema: pair p1 artifact[0] needs a non-blank command string, got ["git","config"]'

  # One entry holding both forms is ambiguous about which one the gate
  # reads, so it is refused rather than checked as either.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].artifact = [{file: "scripts/tool.sh", lines: "1-5",
      command: "git config --local --get x", observed: "exit 1"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case artifact-command-and-file "${d}" 1 \
    'schema: pair p1 artifact[0] holds both command and file keys (command, file, lines, observed)'

  # A lines range with no file is still half of a file entry, and an
  # observed with no command is half of a command entry.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].artifact = [{lines: "1-5", command: "git config --local --get x", observed: "exit 1"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case artifact-command-and-lines "${d}" 1 \
    'schema: pair p1 artifact[0] holds both command and file keys (command, lines, observed)'

  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].artifact = [{file: "scripts/tool.sh", lines: "1-5", observed: "exit 1"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case artifact-observed-and-file "${d}" 1 \
    'schema: pair p1 artifact[0] holds both command and file keys (file, lines, observed)'

  # An observed with no command is a command entry missing its command,
  # not a file entry missing its file.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].artifact = [{observed: "exit 1"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case artifact-observed-only "${d}" 1 \
    'schema: pair p1 artifact[0] needs a non-blank command string, got null'
  expect_absent 'needs a file'

  # Each command entry is reported by its own index.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].artifact = [{command: "git config --local --get x", observed: "exit 1"},
      {command: "git config --local --get y"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case artifact-command-second-bad "${d}" 1 \
    'schema: pair p1 artifact[1] needs a non-blank observed string, got null'

  # A leading zero must not slip past the range regex into bash's octal
  # arithmetic later. This targets the pair's own lines field; a malformed
  # artifact entry is reported by its index, as in
  # artifact-command-beside-bad-file.
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
                  "anchor": "Beta paragraph, corrected",
                  "artifact": [{"file": "scripts/tool.sh", "lines": "1-5"}],
                  "fix_shape": "scope", "siblings": []}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case pair-lines-past-end "${d}" 1 \
    'schema: pair p1 docs/a.md:9000-9999 runs past end of file (12 lines)'
  # A range completeness rejects is not searched for its anchor.
  expect_absent 'anchor:'

  # A reversed range is malformed, not too long: a pair range 2-1 and an
  # artifact range 3-1 each say start > end, and neither says it runs
  # past the end of a file it fits inside. p2 covers the Beta hunk so the
  # only findings are the two reversed ranges.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].lines = "2-1" |
      .pairs += [{"id": "p2", "finding": 2, "file": "docs/a.md", "lines": "6-6",
                  "anchor": "Beta paragraph, corrected",
                  "artifact": [{"file": "scripts/tool.sh", "lines": "3-1"}],
                  "fix_shape": "scope", "siblings": []}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  jq '.pairs += [.pairs[0] | .id = "p2"]' "${d}/gate.json" >"${d}/g" && mv -- "${d}/g" "${d}/gate.json"
  run_case pair-range-reversed "${d}" 1 \
    'schema: pair p1 docs/a.md:2-1 is reversed (start 2 > end 1)'
  also_expect 'artifact: pair p2 scripts/tool.sh:3-1 is reversed (start 3 > end 1)'
  expect_absent 'runs past end of file'
  expect_absent 'anchor:'

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
      { id: "p1", finding: 1, file: "docs/a.md", lines: $bad, anchor: "alpha line WRONG.",
        artifact: [{file: "docs/a.md", lines: "1-1"}], fix_shape: "scope", siblings: [] },
      { id: "p1", finding: 2, file: "docs/a.md", lines: "4-4", anchor: "alpha line WRONG.",
        artifact: [{file: "docs/a.md", lines: "1-1"}], fix_shape: "scope", siblings: [] }
    ]}' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case range-trailing-newline "${d}" 1 'schema: pair id p1 is used more than once'
  also_expect 'schema: pair p1 needs id, file and a <start>-<end> lines'

  # A file named with a leading "./" or "/" never equals a path git
  # prints, so a pair on "./docs/a.md" would leave its own hunk reading
  # as uncovered, with nothing pointing at the pair. Each file field, in
  # a pair, an artifact, a sibling and a code change, is refused by name.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].file = "./docs/a.md"
    | .pairs[0].artifact[0].file = "/scripts/tool.sh"
    | .pairs[0].siblings = [{file: "./docs/b.md", lines: "1-1", status: "unchanged", reason: "r"}]
    | .code_changes = [{file: "/scripts/tool.sh", evidence: "e"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case file-path-dot-slash "${d}" 1 \
    'schema: pair p1 file "./docs/a.md" starts with ./ or /; name it from the repository root'
  also_expect 'schema: pair p1 artifact file "/scripts/tool.sh" starts with ./ or /'
  also_expect 'schema: pair p1 sibling file "./docs/b.md" starts with ./ or /'
  also_expect 'schema: code_changes file "/scripts/tool.sh" starts with ./ or /'

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

  # The root CHANGELOG.md and tests/fixtures/ sit outside the paragraph
  # check: a word edit in each needs neither a pair nor a code_changes
  # entry. Narrowing the in-scope Markdown set's exclusions makes either
  # edit an uncovered hunk.
  d="$(new_repo)"
  git -C "${d}" switch --quiet main
  mkdir -p -- "${d}/tests/fixtures/deep"
  printf '%s\n' '# Changelog' '' 'Entry one.' >"${d}/CHANGELOG.md"
  printf '%s\n' 'Fixture paragraph.' >"${d}/tests/fixtures/deep/x.md"
  commit_all_special "${d}" out-of-scope CHANGELOG.md tests
  git -C "${d}" switch --quiet fix
  git -C "${d}" merge --quiet main
  sed -i 's/^Entry one\.$/Entry one, reworded./' "${d}/CHANGELOG.md"
  sed -i 's/^Fixture paragraph\.$/Fixture paragraph, reworded./' "${d}/tests/fixtures/deep/x.md"
  commit_all_special "${d}" reword CHANGELOG.md tests
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case out-of-scope-markdown-unpaired "${d}" 0 '' \
    'OK — 0 pairs; 0 hunks covered, 0 reflow-only and 0 generated skipped; 0 code changes; 0 changed, 0 unchanged and 0 removed siblings'

  # Outside in-scope Markdown any touching hunk clears a changed sibling,
  # a whitespace-only edit included. Narrowing the exclusions puts the
  # same trailing space under the substance test, which it fails.
  d="$(new_repo)"
  git -C "${d}" switch --quiet main
  mkdir -p -- "${d}/tests/fixtures/deep"
  printf '%s\n' '# Changelog' '' 'Entry one.' >"${d}/CHANGELOG.md"
  printf '%s\n' 'Fixture paragraph.' >"${d}/tests/fixtures/deep/x.md"
  commit_all_special "${d}" out-of-scope CHANGELOG.md tests
  git -C "${d}" switch --quiet fix
  git -C "${d}" merge --quiet main
  sed -i 's/^Entry one\.$/Entry one. /' "${d}/CHANGELOG.md"
  sed -i 's/^Fixture paragraph\.$/Fixture paragraph. /' "${d}/tests/fixtures/deep/x.md"
  commit_all_special "${d}" pad CHANGELOG.md tests
  beta_fixed "${d}"
  jq '.pairs[0].siblings = [{file: "CHANGELOG.md", lines: "3-3", status: "changed"},
      {file: "tests/fixtures/deep/x.md", lines: "1-1", status: "changed"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case out-of-scope-markdown-sibling "${d}" 0 '' \
    'OK — 1 pairs; 1 hunks covered, 0 reflow-only and 0 generated skipped; 0 code changes; 2 changed, 0 unchanged and 0 removed siblings'

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
            "anchor": "Alpha paragraph line one.",
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

  # A Markdown file replaced by a directory of the same name is a deleted
  # Markdown file: its text is gone, so it must be listed like any other.
  # Only a file (a blob) at head survives as Markdown to pair.
  d="$(new_repo)"
  seed_main "${d}" docs/x.md 'Ex paragraph.'
  git -C "${d}" rm --quiet -- docs/x.md
  mkdir -p -- "${d}/docs/x.md"
  printf 'inner\n' >"${d}/docs/x.md/inner.txt"
  commit_all "${d}" 'md becomes a directory'
  printf '{"report": "r.md", "pairs": [], "code_changes": [{"file": "docs/x.md/inner.txt", "evidence": "e"}]}\n' \
    >"${d}/ledger.json"
  jq -n --arg b "$(git -C "${d}" rev-parse HEAD:docs/x.md/inner.txt)" \
    '{pairs: [], code_changes: [{file: "docs/x.md/inner.txt", blob: $b, attack: "a", result: "r"}]}' \
    >"${d}/gate.json"
  run_case md-replaced-by-directory "${d}" 1 \
    'uncovered-file: docs/x.md is changed but not listed in code_changes'

  # A gitlink named like Markdown is not a file, so it is a code change
  # too. It points at a commit the repository holds, since a missing
  # object already reads as absent at head and would not tell a
  # tracked-name test from a file test.
  d="$(new_repo)"
  git -C "${d}" update-index --add --cacheinfo "160000,$(git -C "${d}" rev-parse HEAD),docs/sub.md"
  git -C "${d}" commit --quiet --message 'gitlink named .md'
  # An empty directory stands for the unpopulated submodule, so the
  # working tree is clean.
  mkdir -p -- "${d}/docs/sub.md"
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case md-named-gitlink "${d}" 1 \
    'uncovered-file: docs/sub.md is changed but not listed in code_changes'

  # A space in a filename must not break hunk attribution.
  d="$(new_repo)"
  printf 'Spaced paragraph.\n' >"${d}/docs/b c.md"
  commit_all "${d}" spaced
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case space-in-name "${d}" 1 'uncovered-hunk: docs/b c.md:1'

  # Git C-quotes a path holding a double quote or a backslash in every
  # diff the checker reads, so no ledger name matches it, except one
  # written as git's quoted text. Listed that way with the blob
  # "deleted", a changed script would pass with an attack tied to no
  # blob. Such a path stops the run instead, named as git prints it.
  d="$(new_repo)"
  printf 'echo q\n' >"${d}/scripts/q\"t.sh"
  commit_all "${d}" quoted
  jq -n '{report: "r.md", pairs: [], code_changes: [{file: "\"scripts/q\\\"t.sh\"", evidence: "e"}]}' \
    >"${d}/ledger.json"
  jq -n '{pairs: [], code_changes: [{file: "\"scripts/q\\\"t.sh\"", blob: "deleted", attack: "a", result: "r"}]}' \
    >"${d}/gate.json"
  run_case quoted-path-code-change "${d}" 2 \
    'cannot check the change to "scripts/q\"t.sh": git quotes a path holding a double quote, backslash or control character; rename it'

  # A Markdown file with a backslash in its name, paired correctly, would
  # otherwise report its own hunk as uncovered under a garbled name.
  d="$(new_repo)"
  seed_main "${d}" 'docs/b\s.md' 'One.' '' 'Two.'
  sed -i 's/^Two\.$/Two, fixed./' "${d}/docs/b\\s.md"
  commit_all "${d}" fix
  jq -n '{report: "r.md", code_changes: [], pairs: [{id: "p1", finding: 1, file: "docs/b\\s.md",
    lines: "3-3", artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "scope", siblings: []}]}' \
    >"${d}/ledger.json"
  jq -n --arg h "$(gate_hash "${d}" 'docs/b\s.md' 3-3)" \
    '{pairs: [{id: "p1", verdict: "TRUE", hash: $h, note: ""}], code_changes: []}' >"${d}/gate.json"
  run_case quoted-path-markdown "${d}" 2 \
    'cannot check the change to "docs/b\\s.md": git quotes a path holding a double quote, backslash or control character; rename it'

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

  # A hunk whose new side is only blank lines anchors, like a pure
  # deletion, on the lines either side of it: "alpha line two." blanked
  # in place leaves Alpha's first line directly above the blank, so a
  # pair on that neighbouring paragraph covers the hunk. The unchanged
  # sibling gives this OK line a tally no other scenario prints.
  d="$(new_repo)"
  sed -i '4s/.*//' "${d}/docs/a.md"
  commit_all "${d}" blank-alpha-two
  jq -n '{report: "r.md", code_changes: [],
    pairs: [{id: "p1", finding: 1, file: "docs/a.md", lines: "3-3",
      anchor: "Alpha paragraph line one.",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "drop",
      sweep: ["alpha line two."],
      siblings: [{file: "docs/a.md", lines: "6-6", status: "unchanged",
        reason: "Beta states nothing the dropped line did"}]}]}' >"${d}/ledger.json"
  jq -n --arg h "$(gate_hash "${d}" docs/a.md 3-3)" \
    '{pairs: [{id: "p1", verdict: "TRUE", hash: $h, note: ""}], code_changes: []}' >"${d}/gate.json"
  run_case blank-replacement-covered-by-neighbour "${d}" 0 '' \
    'OK — 1 pairs; 1 hunks covered, 0 reflow-only and 0 generated skipped; 0 code changes; 0 changed, 1 unchanged and 0 removed siblings; 1 sweep terms, 1 hits cleared'

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
            "anchor": "Delta paragraph.",
            "artifact": [{"file": "docs/a.md", "lines": "8-8"}],
            "fix_shape": "scope", "siblings": []}]}
EOF
  h="$(gate_hash "${d}" docs/a.md 8-8)"
  printf '{"pairs": [{"id": "p1", "verdict": "TRUE", "hash": "%s", "note": ""}], "code_changes": []}\n' \
    "${h}" >"${d}/gate.json"
  run_case forged-block-after-end "${d}" 1 'uncovered-hunk: docs/a.md:13'

  # A .md file git treats as binary (a NUL byte forces this) gets a real
  # hunk from list_hunks' --text, so it needs a pair like any other new
  # paragraph, not a code_changes entry.
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
  # Its range is 1-1, which git's listing of the tree holds, so only the
  # file check keeps its anchor from being searched.
  jq '.pairs[0].file = "docs" | .pairs[0].lines = "1-1" |
      .pairs += [{"id": "p2", "finding": 2, "file": "docs/a.md", "lines": "6-6",
                  "anchor": "Beta paragraph, corrected",
                  "artifact": [{"file": "scripts/tool.sh", "lines": "1-5"}],
                  "fix_shape": "scope", "siblings": []}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case pair-file-directory "${d}" 1 'schema: pair p1 file docs is not a file at the head revision'
  expect_absent 'anchor:'

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

  # A "-diff" .md file listed in code_changes still needs a pair for its
  # content, because list_hunks' --text gives it a real hunk. Four
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
    {id: "p1", finding: 1, file: "docs/a.md", lines: "6-6", anchor: "Beta paragraph, corrected",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "scope",
      sweep: ["Beta paragraph.", "Gamma paragraph."],
      siblings: [{file: "docs/a.md", lines: "12-12", status: "changed"},
        {file: "docs/a.md", lines: "3-4", status: "unchanged", reason: "already scoped"}]},
    {id: "p2", finding: 1, file: "docs/a.md", lines: "12-12", anchor: "Gamma paragraph, corrected",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "scope", siblings: []}]}' \
    >"${d}/ledger.json"
  run_case sibling-changed "${d}" 0 '' \
    'OK — 2 pairs; 2 hunks covered, 0 reflow-only and 0 generated skipped; 0 code changes; 1 changed, 1 unchanged and 0 removed siblings; 2 sweep terms, 2 hits cleared'

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
      anchor: "Alpha paragraph line one.",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct",
      sweep: ["Alpha paragraph line one."], siblings: []}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  jq --arg h "$(gate_hash "${d}" docs/a.md 3-5)" '.pairs += [{id: "p2", verdict: "TRUE", hash: $h, note: ""}]' \
    "${d}/gate.json" >"${d}/g" && mv -- "${d}/g" "${d}/gate.json"
  run_case moved-paragraph "${d}" 0 '' \
    'OK — 2 pairs; 2 hunks covered, 0 reflow-only and 0 generated skipped; 0 code changes; 0 changed, 0 unchanged and 0 removed siblings; 2 sweep terms, 2 hits cleared'

  # Negative fixture N3: pair recorded on Alpha's first line only, gated,
  # then Alpha's second line edited. Same block, so the verdict is stale.
  # Guards against hashing the recorded lines instead of the whole block.
  d="$(new_repo)"
  sed -i 's/^Alpha paragraph line one\.$/Alpha paragraph line one, fixed./' "${d}/docs/a.md"
  commit_all "${d}" alpha
  jq -n '{report: "r.md", code_changes: [], pairs: [{id: "p1", finding: 1, file: "docs/a.md", lines: "3-3",
    anchor: "Alpha paragraph line one, fixed.",
    artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "scope", siblings: []}]}' >"${d}/ledger.json"
  jq -n --arg h "$(gate_hash "${d}" docs/a.md 3-3)" \
    '{pairs: [{id: "p1", verdict: "TRUE", hash: $h, note: ""}], code_changes: []}' >"${d}/gate.json"
  sed -i 's/^alpha line two\.$/alpha line two, edited after the gate./' "${d}/docs/a.md"
  commit_all "${d}" 'post-gate same block'
  run_case stale-same-block "${d}" 1 'stale-verdict: pair p1 docs/a.md:3-3 changed after the gate read it'

  # A pair's lines must hold its anchor, the one place the file holds it,
  # so a range a later commit moved cannot carry a verdict to another
  # paragraph. Shift: Alpha is fixed and paired at 3-4, then a paragraph
  # inserted above moves it to 5-6. The stale 3-4 is the new paragraph and
  # the blank line after it, whose block runs on into Alpha, so it covers
  # Alpha's hunk and a gate hashing it there matches. Only the rule that a
  # pair's lines hold no blank line decides it: the anchor sits at 5.
  d="$(new_repo)"
  sed -i 's/^alpha line two\.$/alpha line two, fixed./' "${d}/docs/a.md"
  commit_all "${d}" 'fix alpha'
  sed -i '3i Inserted paragraph.\n' "${d}/docs/a.md"
  commit_all "${d}" 'insert above alpha'
  jq -n '{report: "r.md", code_changes: [], pairs: [
    {id: "p1", finding: 1, file: "docs/a.md", lines: "3-4", anchor: "alpha line two, fixed.",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct",
      sweep: ["alpha line two."], siblings: []},
    {id: "p2", finding: 1, file: "docs/a.md", lines: "3-3", anchor: "Inserted paragraph.",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct", siblings: []}]}' \
    >"${d}/ledger.json"
  gate_all "${d}"
  run_case anchor-shift-blank-range "${d}" 1 \
    'schema: pair p1 docs/a.md:3-4 holds a blank line; a pair'"'"'s lines lie inside one paragraph'
  expect_absent 'anchor:'
  expect_absent 'uncovered-hunk'

  # Swap: two fixed paragraphs trade places after the ledger was written,
  # and a gate hashes each at its recorded lines. Each range still holds
  # one whole paragraph, and each paragraph is covered, so only the
  # anchor tells them apart. p2 shares p1's finding and carries no terms.
  d="$(new_repo)"
  seed_main "${d}" docs/s.md '# S' '' 'First claim, old.' '' 'Second claim, old.' '' 'Tail.'
  printf '%s\n' '# S' '' 'First claim, new.' '' 'Second claim, new.' '' 'Tail.' >"${d}/docs/s.md"
  commit_all "${d}" 'fix both claims'
  printf '%s\n' '# S' '' 'Second claim, new.' '' 'First claim, new.' '' 'Tail.' >"${d}/docs/s.md"
  commit_all "${d}" 'swap them'
  jq -n '{report: "r.md", code_changes: [], pairs: [
    {id: "p1", finding: 1, file: "docs/s.md", lines: "3-3", anchor: "First claim, new.",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct",
      sweep: ["First claim, old."], siblings: []},
    {id: "p2", finding: 1, file: "docs/s.md", lines: "5-5", anchor: "Second claim, new.",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct", siblings: []}]}' \
    >"${d}/ledger.json"
  gate_all "${d}"
  run_case anchor-swap "${d}" 1 \
    'anchor: pair p1 anchor "First claim, new." is at docs/s.md:5-5, outside its lines 3-3; point lines at it or anchor on text inside them'
  also_expect 'anchor: pair p2 anchor "Second claim, new." is at docs/s.md:3-3, outside its lines 5-5; point lines at it or anchor on text inside them'

  # An anchor wrapped across two lines must lie wholly inside the lines:
  # the end of the match past them (p1) or its start before them (p2) is
  # outside. A match the file holds twice is refused even when one copy
  # sits inside the lines (p3), and one it holds nowhere is reported
  # (p4); a heading's "#" run is stripped from the text, so an anchor
  # that includes it matches nothing (p5).
  d="$(new_repo)"
  sed -i -e 's/^Alpha paragraph line one\.$/Alpha paragraph line one, fixed./' \
    -e 's/^Gamma paragraph\.$/Gamma paragraph. Beta paragraph, corrected./' "${d}/docs/a.md"
  sed -i 's/^Beta paragraph\.$/Beta paragraph, corrected./' "${d}/docs/a.md"
  commit_all "${d}" 'fix alpha, beta and gamma'
  jq -n '{report: "r.md", code_changes: [], pairs: [
    {id: "p1", finding: 1, file: "docs/a.md", lines: "3-3", anchor: "fixed. alpha line",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct",
      sweep: ["Alpha paragraph line one."], siblings: []},
    {id: "p2", finding: 1, file: "docs/a.md", lines: "4-4", anchor: "one, fixed. alpha line two.",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct", siblings: []},
    {id: "p3", finding: 1, file: "docs/a.md", lines: "6-6", anchor: "paragraph, corrected.",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct", siblings: []},
    {id: "p4", finding: 1, file: "docs/a.md", lines: "12-12", anchor: "Gamma paragraph, fixed.",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct", siblings: []},
    {id: "p5", finding: 1, file: "docs/a.md", lines: "1-1", anchor: "# A",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct", siblings: []},
    {id: "p6", finding: 1, file: "docs/a.md", lines: "12-12", anchor: "paragraph",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct", siblings: []}]}' \
    >"${d}/ledger.json"
  gate_all "${d}"
  run_case anchor-placement "${d}" 1 \
    'anchor: pair p1 anchor "fixed. alpha line" is at docs/a.md:3-4, outside its lines 3-3; point lines at it or anchor on text inside them'
  also_expect 'anchor: pair p2 anchor "one, fixed. alpha line two." is at docs/a.md:3-4, outside its lines 4-4'
  also_expect 'anchor: pair p3 anchor "paragraph, corrected." matches docs/a.md more than once (6-6 12-12); name a phrase the file holds once'
  also_expect 'anchor: pair p4 anchor "Gamma paragraph, fixed." matches nothing in docs/a.md at the head revision'
  also_expect 'anchor: pair p5 anchor "# A" matches nothing in docs/a.md at the head revision'
  # Gamma's line holds "paragraph" twice; its position is listed once.
  also_expect 'anchor: pair p6 anchor "paragraph" matches docs/a.md more than once (3-3 6-6 12-12); name a phrase the file holds once'

  # An anchor that is its paragraph's whole text passes even where the
  # file repeats it: a heading, whose "#" run the match strips, renamed to
  # a word the prose uses (p1), and a line fixed to match another
  # paragraph word for word (p2). Identical paragraphs hash alike, so a
  # range on either carries the same verdict.
  d="$(new_repo)"
  seed_main "${d}" docs/h.md '# H' '' '## Wrong name' '' 'Usage of the tool is below.' '' 'Same line.' \
    '' 'Same line, old.' '' 'Twin a' 'twin b' '' 'Twin a' 'twin b'
  sed -i -e 's/^## Wrong name$/## Usage/' -e 's/^Same line, old\.$/Same line./' "${d}/docs/h.md"
  commit_all "${d}" 'rename usage, fix same line'
  jq -n '{report: "r.md", code_changes: [], pairs: [
    {id: "p1", finding: 1, file: "docs/h.md", lines: "3-3", anchor: "Usage",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct",
      sweep: ["Wrong name", "Wrong"], siblings: []},
    {id: "p2", finding: 2, file: "docs/h.md", lines: "9-9", anchor: "Same line.",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct",
      sweep: ["Same line, old."],
      siblings: [{file: "docs/h.md", lines: "7-7", status: "unchanged",
        reason: "the line it now matches was already right"}]}]}' >"${d}/ledger.json"
  gate_all "${d}"
  run_case anchor-whole-paragraph "${d}" 0 '' \
    'OK — 2 pairs; 2 hunks covered, 0 reflow-only and 0 generated skipped; 0 code changes; 0 changed, 1 unchanged and 0 removed siblings; 3 sweep terms, 2 hits cleared'

  # The exception is only for the whole text of the paragraph at lines:
  # the same word as part of a longer paragraph is a repeat (p3), and a
  # whole two-line paragraph the lines hold only half of is outside them,
  # at every place it matched (p4).
  jq '.pairs += [
    {id: "p3", finding: 1, file: "docs/h.md", lines: "5-5", anchor: "Usage",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct", siblings: []},
    {id: "p4", finding: 1, file: "docs/h.md", lines: "11-11", anchor: "Twin a twin b",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct", siblings: []}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  gate_all "${d}"
  run_case anchor-whole-paragraph-limits "${d}" 1 \
    'anchor: pair p3 anchor "Usage" matches docs/h.md more than once (3-3 5-5); name a phrase the file holds once'
  also_expect 'anchor: pair p4 anchor "Twin a twin b" is at docs/h.md (11-12 14-15), outside its lines 11-11; point lines at it or anchor on text inside them'
  expect_absent 'pair p1'
  expect_absent 'pair p2'

  # A range that starts on a blank line (p1), ends on one (p2), is one
  # (p3) or holds one between two lines of text (p4) is refused even
  # though each holds or borders Beta's anchor: its block would run over
  # both neighbouring paragraphs.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs += [
      {id: "p2", finding: 1, file: "docs/a.md", lines: "6-7", anchor: "Beta paragraph, corrected",
        artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct", siblings: []},
      {id: "p3", finding: 1, file: "docs/a.md", lines: "7-7", anchor: "Beta paragraph, corrected",
        artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct", siblings: []},
      {id: "p4", finding: 1, file: "docs/a.md", lines: "4-6", anchor: "Beta paragraph, corrected",
        artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct", siblings: []}]
    | .pairs[0].lines = "5-6"' "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  gate_all "${d}"
  run_case anchor-blank-edges "${d}" 1 \
    'schema: pair p1 docs/a.md:5-6 holds a blank line; a pair'"'"'s lines lie inside one paragraph'
  also_expect 'schema: pair p2 docs/a.md:6-7 holds a blank line'
  also_expect 'schema: pair p3 docs/a.md:7-7 holds a blank line'
  also_expect 'schema: pair p4 docs/a.md:4-6 holds a blank line'
  expect_absent 'anchor:'

  # The anchor is required, and is a sweep term's shape: text, no
  # newline, tab or CR. Text made only of white space and zero-width
  # characters is blank.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs += [range(2; 7) as $i | .pairs[0] | .id = "p\($i)"]
    | del(.pairs[1].anchor) | .pairs[2].anchor = 3 | .pairs[3].anchor = " ​"
    | .pairs[4].anchor = "a\nb" | .pairs[5].anchor = "a\tb"
    | .pairs += [.pairs[0] | .id = "p7" | .anchor = "Beta\u0000 paragraph, corrected"]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case schema-anchor "${d}" 1 \
    'schema: pair p2 needs an anchor (a non-blank phrase inside its lines, with no newline, tab, CR or NUL), got null'
  also_expect 'schema: pair p3 needs an anchor (a non-blank phrase inside its lines, with no newline, tab, CR or NUL), got 3'
  also_expect $'schema: pair p4 needs an anchor (a non-blank phrase inside its lines, with no newline, tab, CR or NUL), got " ​"'
  also_expect 'schema: pair p5 needs an anchor (a non-blank phrase inside its lines, with no newline, tab, CR or NUL), got "a<LF>b"'
  also_expect 'schema: pair p6 needs an anchor (a non-blank phrase inside its lines, with no newline, tab, CR or NUL), got "a<TAB>b"'
  also_expect 'schema: pair p7 needs an anchor (a non-blank phrase inside its lines, with no newline, tab, CR or NUL), got "Beta<NUL> paragraph, corrected"'
  expect_absent 'ignored null byte'
  expect_absent 'pair p1 needs an anchor'

  # Anchors in the shapes a real ledger carries pass: a list item and a
  # table row inside a larger block, text wrapped across lines, non-ASCII
  # text, a file's first and last lines, and text inside a generated
  # block, which an anchor is matched in though a sweep skips it.
  d="$(new_repo)"
  seed_main "${d}" docs/l.md 'Intro line, old.' '' '- one' '- two old' '- three' '' '| k | v |' \
    '| - | - |' '| x | old |' '' 'Café tail, old.'
  printf '%s\n' 'Intro line, new.' '' '- one' '- two fixed' '- three' '' '| k | v |' \
    '| - | - |' '| x | fixed |' '' 'Café tail, new.' >"${d}/docs/l.md"
  sed -i 's/^alpha line two\.$/alpha line two, fixed./' "${d}/docs/a.md"
  commit_all "${d}" 'fix list, table, ends and alpha'
  jq -n '{report: "r.md", code_changes: [], pairs: [
    {id: "p1", finding: 1, file: "docs/l.md", lines: "4-4", anchor: "- two fixed",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct",
      sweep: ["two old"], siblings: []},
    {id: "p2", finding: 2, file: "docs/l.md", lines: "9-9", anchor: "| x | fixed |",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct",
      sweep: ["x | old"], siblings: []},
    {id: "p3", finding: 3, file: "docs/l.md", lines: "1-1", anchor: "Intro line, new.",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct",
      sweep: ["Intro line, old."], siblings: []},
    {id: "p4", finding: 4, file: "docs/l.md", lines: "11-11", anchor: "Café tail, new.",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct",
      sweep: ["Café tail, old."], siblings: []},
    {id: "p5", finding: 5, file: "docs/a.md", lines: "3-4", anchor: "line one. alpha line two,",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct",
      sweep: ["alpha line two."], siblings: []},
    {id: "p6", finding: 5, file: "docs/a.md", lines: "9-9", anchor: "generated row one",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct", siblings: []}]}' \
    >"${d}/ledger.json"
  gate_all "${d}"
  run_case anchor-shapes-pass "${d}" 0 '' \
    'OK — 6 pairs; 5 hunks covered, 0 reflow-only and 0 generated skipped; 0 code changes; 0 changed, 0 unchanged and 0 removed siblings; 5 sweep terms, 5 hits cleared'

  # A listed code change with a gate attack: pass.
  d="$(new_repo)"
  sed -i 's/^echo line5$/echo line5 changed/' "${d}/scripts/tool.sh"
  commit_all "${d}" code
  printf '{"report": "r.md", "pairs": [], "code_changes": [{"file": "scripts/tool.sh", "evidence": "harness"}]}\n' \
    >"${d}/ledger.json"
  jq -n --arg b "$(git -C "${d}" rev-parse HEAD:scripts/tool.sh)" \
    '{pairs: [], code_changes: [{file: "scripts/tool.sh", blob: $b, attack: "empty input", result: "exit 2"}]}' \
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
  jq -n --arg b "$(git -C "${d}" rev-parse HEAD:scripts/w.sh)" \
    '{pairs: [], code_changes: [{file: "scripts/w.sh", blob: $b, attack: "  ", result: "exit 2"}]}' \
    >"${d}/gate.json"
  run_case attack-whitespace "${d}" 1 'missing-attack: code change scripts/w.sh has no gate attack and result'

  # Text made only of invisible format characters is blank: a zero-width
  # space (U+200B) and a byte-order mark (U+FEFF) print nothing, so a
  # command or observed made of them records nothing.
  local zwsp bom
  zwsp=$'\xe2\x80\x8b'
  bom=$'\xef\xbb\xbf'
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].artifact = [{command: "​​", observed: "﻿"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case artifact-command-zero-width "${d}" 1 \
    "schema: pair p1 artifact[0] needs a non-blank command string, got \"${zwsp}${zwsp}\""
  also_expect "schema: pair p1 artifact[0] needs a non-blank observed string, got \"${bom}\""

  # The same rule holds for a sibling's reason and a gate attack and
  # result: a word joiner (U+2060) and a soft hyphen (U+00AD) beside
  # ordinary spaces are no reason and no attack.
  d="$(new_repo)"
  beta_fixed "${d}"
  sed -i 's/^echo line5$/echo line5 changed/' "${d}/scripts/tool.sh"
  commit_all "${d}" code
  jq '.pairs[0].siblings = [{file: "docs/a.md", lines: "3-4", status: "unchanged", reason: " ⁠ "}]
    | .code_changes = [{file: "scripts/tool.sh", evidence: "harness"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  jq --arg b "$(git -C "${d}" rev-parse HEAD:scripts/tool.sh)" \
    '.code_changes = [{file: "scripts/tool.sh", blob: $b, attack: "­", result: "exit 2"}]' \
    "${d}/gate.json" >"${d}/g" && mv -- "${d}/g" "${d}/gate.json"
  run_case reason-and-attack-zero-width "${d}" 1 \
    'sibling-reason: pair p1 sibling docs/a.md:3-4 is unchanged with no reason'
  also_expect 'missing-attack: code change scripts/tool.sh has no gate attack and result'

  # An unchanged sibling must name a file that exists at head.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].siblings = [{file: "docs/nope.md", lines: "1-1", status: "unchanged", reason: "n/a"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case sibling-unchanged-untracked "${d}" 1 \
    'sibling-untracked: pair p1 sibling docs/nope.md is not tracked at the head revision'

  # An unchanged sibling's range names the text its reason is about, so
  # it must be a forward <start>-<end> range inside its file like any
  # other sibling's: garbage, a reversed range, a missing one and one past
  # the end are each reported, and each reason is still checked.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].siblings = [
      {file: "docs/a.md", lines: "garbage", status: "unchanged", reason: "r"},
      {file: "docs/a.md", lines: "12-5", status: "unchanged", reason: "r"},
      {file: "docs/a.md", status: "unchanged"},
      {file: "docs/a.md", lines: "900-999", status: "unchanged", reason: "r"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case sibling-unchanged-bad-range "${d}" 1 \
    'schema: pair p1 sibling docs/a.md:garbage is marked unchanged without a valid <start>-<end> range'
  also_expect 'schema: pair p1 sibling docs/a.md:12-5 is marked unchanged without a valid <start>-<end> range'
  also_expect 'schema: pair p1 sibling docs/a.md:- is marked unchanged without a valid <start>-<end> range'
  also_expect 'sibling-reason: pair p1 sibling docs/a.md:- is unchanged with no reason'
  also_expect 'schema: pair p1 sibling docs/a.md:900-999 runs past end of file (12 lines)'
  also_expect 'check-fix-ledger: 5 finding(s) (schema 4, sibling-reason 1)'

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
  sibling_ledger "${d}" docs/t.md 5-5 '| x | corrected |' 6-6
  run_case sibling-table-realigned "${d}" 1 \
    'sibling-not-changed: pair p1 sibling docs/t.md:6-6 is marked changed but no covered hunk changes its text'

  # Negative fixture: a trailing space on the sibling item, in the same
  # hunk as the fix to the item above it.
  d="$(new_repo)"
  seed_main "${d}" docs/l.md '- one wrong' '- two wrong'
  printf '%s\n' '- one right' '- two wrong ' >"${d}/docs/l.md"
  commit_all "${d}" 'fix one, pad two'
  sibling_ledger "${d}" docs/l.md 1-1 'one right' 2-2
  run_case sibling-list-trailing-space "${d}" 1 \
    'sibling-not-changed: pair p1 sibling docs/l.md:2-2 is marked changed but no covered hunk changes its text'

  # Positive control: the sibling item's words change in the same hunk.
  d="$(new_repo)"
  seed_main "${d}" docs/l.md '- one wrong' '- two wrong'
  printf '%s\n' '- one right' '- two right' >"${d}/docs/l.md"
  commit_all "${d}" 'fix both'
  sibling_ledger "${d}" docs/l.md 1-1 'one right' 2-2 changed '["one wrong", "two wrong"]'
  run_case sibling-list-word-change "${d}" 0 '' \
    'OK — 1 pairs; 1 hunks covered, 0 reflow-only and 0 generated skipped; 0 code changes; 1 changed, 0 unchanged and 0 removed siblings; 2 sweep terms, 2 hits cleared'

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
  sibling_ledger "${d}" docs/l.md 1-1 'one right' 2-2 removed '["one wrong", "two wrong"]'
  run_case sibling-removed "${d}" 0 '' \
    'OK — 1 pairs; 1 hunks covered, 0 reflow-only and 0 generated skipped; 0 code changes; 0 changed, 0 unchanged and 1 removed siblings; 2 sweep terms, 2 hits cleared'

  # A hunk that only adds lines removed nothing.
  d="$(new_repo)"
  seed_main "${d}" docs/l.md '- one' '- three'
  printf '%s\n' '- one' '- two' '- three' >"${d}/docs/l.md"
  commit_all "${d}" 'add two'
  sibling_ledger "${d}" docs/l.md 2-2 '- two' 3-3 removed
  run_case sibling-removed-nothing-deleted "${d}" 1 \
    'sibling-not-removed: pair p1 sibling docs/l.md:3-3 is marked removed but no covered hunk deletes text there'

  # The only deleted line reappears re-indented, so no text was removed.
  d="$(new_repo)"
  seed_main "${d}" docs/w.md 'Alpha.' '- two'
  printf '%s\n' 'Alpha.' 'New line.' '  - two' >"${d}/docs/w.md"
  commit_all "${d}" 'insert and indent'
  sibling_ledger "${d}" docs/w.md 2-2 'New line.' 3-3 removed
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
  # line 6; no pair's paragraph takes in lines 5-7, so it is uncovered.
  # histogram shapes the same change into hunks the pairs do cover. The
  # checker diffs with myers whatever the repository or user configures.
  d="$(new_repo)"
  seed_main "${d}" docs/p.md '' z z y '' x z y '' '' z z
  printf '%s\n' x '' z z '' '' z y '' q '' z z >"${d}/docs/p.md"
  commit_all "${d}" 'reshape p'
  git -C "${d}" config diff.algorithm histogram
  local pl
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  for pl in 1 3 4 10 12 13; do
    jq --arg l "${pl}-${pl}" --arg an "$(sed --quiet "${pl}p" "${d}/docs/p.md")" \
      '.pairs += [{id: "p\($l)", finding: 1, file: "docs/p.md", lines: $l, anchor: $an,
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "drop", siblings: []}]' \
      "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
    jq --arg l "${pl}-${pl}" --arg h "$(gate_hash "${d}" docs/p.md "${pl}-${pl}")" \
      '.pairs += [{id: "p\($l)", verdict: "TRUE", hash: $h, note: ""}]' \
      "${d}/gate.json" >"${d}/g" && mv -- "${d}/g" "${d}/gate.json"
  done
  run_case diff-algorithm-configured "${d}" 1 'uncovered-hunk: docs/p.md:6 changed and no pair covers it'

  # A code change edited after the gate attacked it: the attack ran
  # against a blob HEAD no longer holds.
  d="$(new_repo)"
  sed -i 's/^echo line5$/echo line5 changed/' "${d}/scripts/tool.sh"
  commit_all "${d}" code
  printf '{"report": "r.md", "pairs": [], "code_changes": [{"file": "scripts/tool.sh", "evidence": "harness"}]}\n' \
    >"${d}/ledger.json"
  jq -n --arg b "$(git -C "${d}" rev-parse HEAD:scripts/tool.sh)" \
    '{pairs: [], code_changes: [{file: "scripts/tool.sh", blob: $b, attack: "empty input", result: "exit 2"}]}' \
    >"${d}/gate.json"
  sed -i 's/^echo line6$/echo line6 edited after the gate/' "${d}/scripts/tool.sh"
  commit_all "${d}" 'post-gate code edit'
  run_case stale-attack "${d}" 1 'stale-attack: code change scripts/tool.sh changed after the gate attacked it'

  # An attack that records no blob cannot be tied to what it attacked.
  d="$(new_repo)"
  sed -i 's/^echo line5$/echo line5 changed/' "${d}/scripts/tool.sh"
  commit_all "${d}" code
  printf '{"report": "r.md", "pairs": [], "code_changes": [{"file": "scripts/tool.sh", "evidence": "harness"}]}\n' \
    >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": [{"file": "scripts/tool.sh", "attack": "empty input", "result": "exit 2"}]}\n' \
    >"${d}/gate.json"
  run_case attack-missing-blob "${d}" 1 'schema: gate code change scripts/tool.sh needs a blob'

  # A blob that is neither an object id nor "deleted" is malformed.
  jq '.code_changes[0].blob = "HEAD"' "${d}/gate.json" >"${d}/g" && mv -- "${d}/g" "${d}/gate.json"
  run_case attack-malformed-blob "${d}" 1 'schema: gate code change scripts/tool.sh needs a blob'

  # A deleted file's attack records the blob "deleted", which matches a
  # file absent at head; the same record on a file still present is stale.
  # A replacement script lands alongside, attacked by its own blob.
  d="$(new_repo)"
  git -C "${d}" rm --quiet -- scripts/tool.sh
  mkdir -p -- "${d}/scripts"
  printf 'echo new\n' >"${d}/scripts/new.sh"
  commit_all "${d}" 'replace tool'
  printf '{"report": "r.md", "pairs": [], "code_changes": [{"file": "scripts/tool.sh", "evidence": "gone"}, {"file": "scripts/new.sh", "evidence": "harness"}]}\n' \
    >"${d}/ledger.json"
  jq -n --arg b "$(git -C "${d}" rev-parse HEAD:scripts/new.sh)" \
    '{pairs: [], code_changes: [{file: "scripts/tool.sh", blob: "deleted", attack: "callers", result: "none left"},
      {file: "scripts/new.sh", blob: $b, attack: "empty input", result: "exit 2"}]}' >"${d}/gate.json"
  run_case attack-deleted-file "${d}" 0 '' \
    'OK — 0 pairs; 0 hunks covered, 0 reflow-only and 0 generated skipped; 2 code changes'
  d="$(new_repo)"
  sed -i 's/^echo line5$/echo line5 changed/' "${d}/scripts/tool.sh"
  commit_all "${d}" code
  printf '{"report": "r.md", "pairs": [], "code_changes": [{"file": "scripts/tool.sh", "evidence": "harness"}]}\n' \
    >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": [{"file": "scripts/tool.sh", "blob": "deleted", "attack": "callers", "result": "none left"}]}\n' \
    >"${d}/gate.json"
  run_case attack-deleted-but-present "${d}" 1 'stale-attack: code change scripts/tool.sh changed after the gate attacked it'

  # A removed sibling in a file the branch deletes: the file exists at the
  # merge base and not at head, so the diff removed its text. The deleted
  # file is a code change like any other.
  d="$(new_repo)"
  seed_main "${d}" docs/gone.md '# Gone' '' 'Gone paragraph.'
  git -C "${d}" rm --quiet -- docs/gone.md
  beta_fixed "${d}"
  jq '.pairs[0].siblings = [{file: "docs/gone.md", lines: "3-3", status: "removed"}]
    | .code_changes = [{file: "docs/gone.md", evidence: "whole page retired"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  jq '.code_changes = [{file: "docs/gone.md", blob: "deleted", attack: "links to it", result: "none left"}]' \
    "${d}/gate.json" >"${d}/g" && mv -- "${d}/g" "${d}/gate.json"
  run_case sibling-removed-file-deleted "${d}" 0 '' \
    'OK — 1 pairs; 1 hunks covered, 0 reflow-only and 0 generated skipped; 1 code changes; 0 changed, 0 unchanged and 1 removed siblings; 1 sweep terms, 1 hits cleared'

  # A deleted file has no head position for its text, so a removed
  # sibling there names the lines the text held at the merge base, and
  # they must exist: gone.md had three lines, so 3-4 runs past its end.
  # A deleted file has no deletion point to sit one past, unlike a file
  # still present at head.
  d="$(new_repo)"
  seed_main "${d}" docs/gone.md '# Gone' '' 'Gone paragraph.'
  git -C "${d}" rm --quiet -- docs/gone.md
  beta_fixed "${d}"
  jq '.pairs[0].siblings = [{file: "docs/gone.md", lines: "3-4", status: "removed"}]
    | .code_changes = [{file: "docs/gone.md", evidence: "whole page retired"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  jq '.code_changes = [{file: "docs/gone.md", blob: "deleted", attack: "links to it", result: "none left"}]' \
    "${d}/gate.json" >"${d}/g" && mv -- "${d}/g" "${d}/gate.json"
  run_case sibling-removed-file-deleted-past-end "${d}" 1 \
    'schema: pair p1 sibling docs/gone.md:3-4 runs past end of file at the merge base (3 lines)'

  # A removed sibling in a file that exists at neither revision names
  # nothing the diff could have deleted.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0].siblings = [{file: "docs/never.md", lines: "3-3", status: "removed"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case sibling-removed-file-never-existed "${d}" 1 \
    'sibling-not-removed: pair p1 sibling docs/never.md:3-3 is marked removed but is absent at the head revision and not a file at the merge base'

  # A caller's diff.ignoreSubmodules=all must not hide a gitlink change:
  # the changed gitlink is a changed file that needs a code_changes entry.
  d="$(new_repo)"
  git -C "${d}" switch --quiet main
  git -C "${d}" update-index --add --cacheinfo "160000,$(git -C "${d}" rev-parse HEAD),sub"
  git -C "${d}" commit --quiet --message 'add gitlink'
  git -C "${d}" switch --quiet fix
  git -C "${d}" merge --quiet main
  git -C "${d}" update-index --cacheinfo "160000,$(git -C "${d}" rev-parse HEAD),sub"
  git -C "${d}" commit --quiet --message 'move gitlink'
  git -C "${d}" config diff.ignoreSubmodules all
  printf '{"report": "r.md", "pairs": [], "code_changes": []}\n' >"${d}/ledger.json"
  printf '{"pairs": [], "code_changes": []}\n' >"${d}/gate.json"
  run_case ignore-submodules-configured "${d}" 1 'uncovered-file: sub is changed but not listed in code_changes'

  # A changed sibling on a gitlink is cleared by the gitlink's own hunk.
  # A caller's diff.ignoreSubmodules=all would drop that hunk, and
  # diff.submodule=log would replace it with a one-line summary the hunk
  # parser never sees; either way the sibling would fail for this caller
  # and pass for another.
  d="$(new_repo)"
  git -C "${d}" switch --quiet main
  git -C "${d}" update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,sub
  git -C "${d}" commit --quiet --message 'add gitlink'
  git -C "${d}" switch --quiet fix
  git -C "${d}" merge --quiet main
  git -C "${d}" update-index --cacheinfo 160000,2222222222222222222222222222222222222222,sub
  git -C "${d}" commit --quiet --message 'move gitlink'
  beta_fixed "${d}"
  git -C "${d}" config diff.ignoreSubmodules all
  git -C "${d}" config diff.submodule log
  jq '.pairs[0].siblings = [{file: "sub", lines: "1-1", status: "changed"}]
    | .code_changes = [{file: "sub", evidence: "pointer bump"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  jq --arg b "$(git -C "${d}" rev-parse HEAD:sub)" \
    '.code_changes = [{file: "sub", blob: $b, attack: "old pointer", result: "fails"}]' \
    "${d}/gate.json" >"${d}/g" && mv -- "${d}/g" "${d}/gate.json"
  run_case gitlink-sibling-submodule-config "${d}" 0 '' \
    'OK — 1 pairs; 1 hunks covered, 0 reflow-only and 0 generated skipped; 1 code changes; 1 changed, 0 unchanged and 0 removed siblings; 1 sweep terms, 1 hits cleared'

  # --- Sweep terms. A pair's sweep terms are searched at the merge base
  # over the sweep scope; every hit must sit in the pair's own paragraph
  # or in one of its sibling ranges, mapped to head.

  # A twin elsewhere with no entry in the pair is reported with its
  # merge-base and head positions.
  d="$(new_repo)"
  seed_files "${d}" docs/b.md $'# B\n\nBeta paragraph. Twin.'
  beta_fixed "${d}"
  run_case sweep-uncovered-twin "${d}" 1 \
    'sweep-uncovered: pair p1 term "Beta paragraph." hits docs/b.md:3-3 at the merge base (3-3 at head) and no entry of the pair covers it'

  # An unchanged sibling on the twin clears it.
  d="$(new_repo)"
  seed_files "${d}" docs/b.md $'# B\n\nBeta paragraph. Twin.'
  beta_fixed "${d}"
  sweep_case "${d}" '["Beta paragraph."]' \
    '[{"file": "docs/b.md", "lines": "3-3", "status": "unchanged", "reason": "true as written"}]'
  run_case sweep-unchanged-sibling "${d}" 0 '' \
    '0 code changes; 0 changed, 1 unchanged and 0 removed siblings; 1 sweep terms, 2 hits cleared'

  # A sibling on the same lines of another file does not clear a hit.
  d="$(new_repo)"
  seed_files "${d}" docs/d.md $'# D\n\nIntro.\n\nBeta paragraph. Twin in d.' docs/c.md $'# C\n\nIntro.\n\nUnrelated.'
  beta_fixed "${d}"
  sweep_case "${d}" '["Beta paragraph."]' \
    '[{"file": "docs/c.md", "lines": "5-5", "status": "unchanged", "reason": "true as written"}]'
  run_case sweep-sibling-other-file "${d}" 1 \
    'sweep-uncovered: pair p1 term "Beta paragraph." hits docs/d.md:5-5 at the merge base (5-5 at head) and no entry of the pair covers it'
  expect_absent 'docs/c.md'

  # Lines inserted above an untouched twin shift it: the sibling names
  # the head line, and the merge-base line number no longer covers it.
  d="$(new_repo)"
  seed_files "${d}" scripts/notes.sh $'#!/usr/bin/env bash\n# Beta paragraph. Twin.\necho done'
  beta_fixed "${d}"
  sed -i '1a\# one\n# two' "${d}/scripts/notes.sh"
  commit_all "${d}" 'shift notes'
  sweep_case "${d}" '["Beta paragraph."]' \
    '[{"file": "scripts/notes.sh", "lines": "4-4", "status": "unchanged", "reason": "true as written"}]' \
    scripts/notes.sh
  run_case sweep-shifted-twin "${d}" 0 '' \
    '1 code changes; 0 changed, 1 unchanged and 0 removed siblings; 1 sweep terms, 2 hits cleared'
  sweep_case "${d}" '["Beta paragraph."]' \
    '[{"file": "scripts/notes.sh", "lines": "2-2", "status": "unchanged", "reason": "true as written"}]' \
    scripts/notes.sh
  run_case sweep-stale-sibling-line "${d}" 1 \
    'hits scripts/notes.sh:2-2 at the merge base (4-4 at head)'

  # A changed twin maps to its hunk's new side.
  d="$(new_repo)"
  seed_files "${d}" scripts/notes.sh $'#!/usr/bin/env bash\n# Beta paragraph. Twin.\necho done'
  beta_fixed "${d}"
  sed -i -e '1a\# one' -e 's/^# Beta paragraph\. Twin\.$/# Beta, corrected twin./' "${d}/scripts/notes.sh"
  commit_all "${d}" 'fix twin'
  sweep_case "${d}" '["Beta paragraph."]' \
    '[{"file": "scripts/notes.sh", "lines": "3-3", "status": "changed"}]' scripts/notes.sh
  run_case sweep-changed-twin "${d}" 0 '' \
    '1 code changes; 1 changed, 0 unchanged and 0 removed siblings; 1 sweep terms, 2 hits cleared'

  # A twin in a file the branch deletes keeps its merge-base lines, and
  # a removed sibling there clears it.
  d="$(new_repo)"
  seed_files "${d}" scripts/old.sh $'#!/usr/bin/env bash\necho x\n# Beta paragraph. Twin.'
  beta_fixed "${d}"
  git -C "${d}" rm --quiet scripts/old.sh
  git -C "${d}" commit --quiet --message 'drop old'
  sweep_case "${d}" '["Beta paragraph."]' '[]' scripts/old.sh
  run_case sweep-deleted-file-twin "${d}" 1 \
    'hits scripts/old.sh:3-3 at the merge base (deleted at head) and no entry'
  sweep_case "${d}" '["Beta paragraph."]' \
    '[{"file": "scripts/old.sh", "lines": "3-3", "status": "removed"}]' scripts/old.sh
  run_case sweep-deleted-file-removed "${d}" 0 '' \
    '1 code changes; 0 changed, 0 unchanged and 1 removed siblings; 1 sweep terms, 2 hits cleared'

  # A twin paragraph deleted outright maps to the lines either side of
  # the deletion, so a removed sibling on the line after it clears it.
  d="$(new_repo)"
  seed_files "${d}" docs/b.md $'# B\n\nLead one.\n\nLead two.\n\nBeta paragraph. Twin.\n\nBravo tail.'
  beta_fixed "${d}"
  printf '%s\n' '# B' '' 'Added.' '' 'Lead one.' '' 'Lead two.' '' 'Bravo tail.' >"${d}/docs/b.md"
  commit_all "${d}" 'drop twin, add a paragraph'
  jq '.pairs += [{id: "p2", finding: 1, file: "docs/b.md", lines: "9-9", anchor: "Bravo tail.",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "drop", siblings: []},
      {id: "p3", finding: 1, file: "docs/b.md", lines: "3-3", anchor: "Added.",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct", siblings: []}]
    | .pairs[0].siblings = [{file: "docs/b.md", lines: "9-9", status: "removed"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  gate_all "${d}"
  run_case sweep-deleted-paragraph "${d}" 0 '' \
    'OK — 3 pairs; 3 hunks covered, 0 reflow-only and 0 generated skipped; 0 code changes; 0 changed, 0 unchanged and 1 removed siblings; 1 sweep terms, 2 hits cleared'

  # A twin line deleted by a hunk that also edits the line above it maps
  # one line past the hunk's new side, where a removed sibling sits.
  d="$(new_repo)"
  seed_files "${d}" docs/b.md $'# B\n\nLead.\n\nOne wrong.\nTwo Beta paragraph. twin.\n\nTail.'
  beta_fixed "${d}"
  printf '%s\n' '# B' '' 'Added.' '' 'Lead.' '' 'One right.' '' 'Tail.' >"${d}/docs/b.md"
  commit_all "${d}" 'add a paragraph, fix one, drop two'
  jq '.pairs += [{id: "p2", finding: 1, file: "docs/b.md", lines: "7-7", anchor: "One right.",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "drop", siblings: []},
      {id: "p3", finding: 1, file: "docs/b.md", lines: "3-3", anchor: "Added.",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct", siblings: []}]
    | .pairs[0].sweep += ["Beta paragraph"]
    | .pairs[0].siblings = [{file: "docs/b.md", lines: "8-8", status: "removed"}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  gate_all "${d}"
  run_case sweep-deleted-after-edit "${d}" 0 '' \
    'OK — 3 pairs; 3 hunks covered, 0 reflow-only and 0 generated skipped; 0 code changes; 0 changed, 0 unchanged and 1 removed siblings; 2 sweep terms, 2 hits cleared'

  # A hit inside another pair's paragraph counts only when this pair
  # lists it as a sibling.
  d="$(new_repo)"
  seed_files "${d}" docs/b.md $'# B\n\nIntro.\n\nBeta paragraph. Twin.'
  beta_fixed "${d}"
  sed -i 's/^Beta paragraph\. Twin\.$/Beta twin, corrected./' "${d}/docs/b.md"
  commit_all "${d}" 'fix twin'
  jq '.pairs += [{id: "p2", finding: 1, file: "docs/b.md", lines: "5-5", anchor: "Beta twin, corrected.",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct", siblings: []}]' \
    "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  gate_all "${d}"
  run_case sweep-other-pair-paragraph "${d}" 1 \
    'sweep-uncovered: pair p1 term "Beta paragraph." hits docs/b.md:5-5 at the merge base (5-5 at head)'

  # The pair's own paragraph counts whole, beyond its recorded lines, and
  # white space in a term is collapsed like the text's.
  d="$(new_repo)"
  sed -i 's/^Alpha paragraph line one\.$/Alpha paragraph, corrected./' "${d}/docs/a.md"
  commit_all "${d}" 'fix alpha'
  jq -n '{report: "r.md", code_changes: [],
    pairs: [{id: "p1", finding: 1, file: "docs/a.md", lines: "3-3",
      anchor: "Alpha paragraph, corrected.",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct",
      sweep: ["alpha line two.", " Alpha  paragraph line one. "], siblings: []}]}' >"${d}/ledger.json"
  gate_all "${d}"
  run_case sweep-own-paragraph "${d}" 0 '' \
    'OK — 1 pairs; 1 hunks covered, 0 reflow-only and 0 generated skipped; 0 code changes; 0 changed, 0 unchanged and 0 removed siblings; 2 sweep terms, 2 hits cleared'

  # A sibling clears by its range, not its block: a script has no blank
  # lines, so its whole body is one block.
  d="$(new_repo)"
  seed_files "${d}" scripts/notes.sh $'#!/usr/bin/env bash\n# Beta paragraph. Twin.\necho a\necho b\necho c'
  beta_fixed "${d}"
  sweep_case "${d}" '["Beta paragraph."]' \
    '[{"file": "scripts/notes.sh", "lines": "5-5", "status": "unchanged", "reason": "true as written"}]'
  run_case sweep-sibling-same-block "${d}" 1 'hits scripts/notes.sh:2-2 at the merge base (2-2 at head)'

  # Matching is wrap-aware: a term split across Markdown lines, and one
  # split across comment lines, each hit with the span it covers.
  d="$(new_repo)"
  seed_files "${d}" docs/b.md $'# B\n\nThe Beta\nparagraph. rule' \
    scripts/notes.sh $'#!/usr/bin/env bash\n# the Beta\n#   paragraph. rule\necho done'
  beta_fixed "${d}"
  run_case sweep-wrapped "${d}" 1 'hits docs/b.md:3-4 at the merge base (3-4 at head)'
  also_expect 'hits scripts/notes.sh:2-3 at the merge base (2-3 at head)'

  # A comment line holding only the marker ends the paragraph, and the
  # marker is not text.
  d="$(new_repo)"
  seed_files "${d}" scripts/notes.sh $'#!/usr/bin/env bash\n# the Beta\n#\n# paragraph. rule'
  beta_fixed "${d}"
  sweep_case "${d}" '["Beta paragraph.", "the Beta paragraph.", "the Beta #"]'
  run_case sweep-comment-break "${d}" 1 \
    'sweep-empty: pair p1 term "the Beta paragraph." matches nothing in the sweep scope at the merge base'
  also_expect 'sweep-empty: pair p1 term "the Beta #" matches nothing'

  # A "#" not followed by white space is text, not a comment marker.
  d="$(new_repo)"
  seed_files "${d}" docs/b.md $'# B\n\n#tagged Beta paragraph. here'
  beta_fixed "${d}"
  sweep_case "${d}" '["Beta paragraph.", "#tagged Beta"]' \
    '[{"file": "docs/b.md", "lines": "3-3", "status": "unchanged", "reason": "true as written"}]'
  run_case sweep-hash-text "${d}" 0 '' \
    '0 code changes; 0 changed, 1 unchanged and 0 removed siblings; 2 sweep terms, 2 hits cleared'

  # A term that matches nothing is reported: a misspelling, a case
  # difference or a regex metacharacter (matched literally) all miss.
  # docs/b.md holds each word of "beta paragraph." in its own case, so the
  # file reaches the matcher, which must still tell the cases apart.
  d="$(new_repo)"
  seed_files "${d}" docs/b.md $'# B\n\nbeta\n\nBeta paragraph. Twin.'
  beta_fixed "${d}"
  sweep_case "${d}" '["Beta paragraph.", "beta paragraph.", "Beta.paragraph", "Nowhere text"]' \
    '[{"file": "docs/b.md", "lines": "5-5", "status": "unchanged", "reason": "true as written"}]'
  run_case sweep-empty-terms "${d}" 1 \
    'sweep-empty: pair p1 term "beta paragraph." matches nothing in the sweep scope at the merge base'
  also_expect 'sweep-empty: pair p1 term "Beta.paragraph" matches nothing'
  also_expect 'sweep-empty: pair p1 term "Nowhere text" matches nothing'
  expect_absent 'term "Beta paragraph." matches nothing'

  # Hits inside a generated block are skipped; the generator is swept.
  d="$(new_repo)"
  beta_fixed "${d}"
  sweep_case "${d}" '["Beta paragraph.", "generated row one"]'
  run_case sweep-generated-skipped "${d}" 1 \
    'sweep-empty: pair p1 term "generated row one" matches nothing'

  # CHANGELOG.md, tests/fixtures/ and flake.lock are outside the sweep.
  d="$(new_repo)"
  seed_files "${d}" CHANGELOG.md 'Beta paragraph. old' \
    tests/fixtures/x/a.md 'Beta paragraph. fixture' flake.lock '{"n": "Beta paragraph."}' \
    .claude/skills/docs-correctness-audit/evals/seeded-defects/fixtures/s.md 'Beta paragraph. seeded' \
    .claude/skills/other/evals/seeded-defects/fixtures/s.md 'Beta paragraph. seeded elsewhere' \
    docs/c.md 'Beta paragraph. in scope'
  beta_fixed "${d}"
  run_case sweep-out-of-scope "${d}" 1 'hits docs/c.md:1-1 at the merge base (1-1 at head)'
  expect_absent 'CHANGELOG.md'
  expect_absent 'tests/fixtures'
  expect_absent 'flake.lock'
  expect_absent 'seeded-defects'

  # Everything else is in the sweep, whatever the tree or extension.
  d="$(new_repo)"
  seed_files "${d}" nix/hooks.nix '# Beta paragraph. nix' \
    tests/h.test.sh '# Beta paragraph. harness' .claude/skills/s/x.sh '# Beta paragraph. skill' \
    justfile '# Beta paragraph. recipe' docs/sub/CHANGELOG.md 'Beta paragraph. nested' \
    docs/sub/flake.lock 'Beta paragraph. nested lock'
  beta_fixed "${d}"
  run_case sweep-scope-reach "${d}" 1 'hits nix/hooks.nix:1-1 at the merge base'
  also_expect 'hits tests/h.test.sh:1-1 at the merge base'
  also_expect 'hits .claude/skills/s/x.sh:1-1 at the merge base'
  also_expect 'hits justfile:1-1 at the merge base'
  also_expect 'hits docs/sub/CHANGELOG.md:1-1 at the merge base'
  also_expect 'hits docs/sub/flake.lock:1-1 at the merge base'

  # A term is read as written: a backslash stays one backslash.
  d="$(new_repo)"
  seed_files "${d}" docs/b.md $'# B\n\nPath a\\b Beta rule here'
  beta_fixed "${d}"
  sweep_case "${d}" '["Beta paragraph.", "a\\b Beta"]'
  run_case sweep-backslash-term "${d}" 1 \
    'sweep-uncovered: pair p1 term "a\b Beta" hits docs/b.md:3-3 at the merge base'

  # The caller's grep and color configuration changes nothing.
  d="$(new_repo)"
  seed_files "${d}" docs/c.md $'# C\n\nBeta paragraph. Twin.'
  beta_fixed "${d}"
  git -C "${d}" config color.ui always
  git -C "${d}" config color.grep always
  git -C "${d}" config grep.patternType perl
  git -C "${d}" config grep.fullName false
  git -C "${d}" config core.quotePath true
  run_case sweep-caller-config "${d}" 1 \
    'sweep-uncovered: pair p1 term "Beta paragraph." hits docs/c.md:3-3 at the merge base (3-3 at head) and no entry of the pair covers it'

  # A binary file is not swept, and a file name outside ASCII is shown
  # as written.
  d="$(new_repo)"
  printf 'x\0Beta paragraph. binary\n' >"${d}/scripts/blob.dat"
  { printf 'Beta paragraph. late NUL\n' && head -c 9000 /dev/zero | tr '\0' 'y' && printf '\n\0'; } >"${d}/scripts/late.dat"
  seed_files "${d}" 'docs/café.md' 'Beta paragraph. accented'
  git -C "${d}" switch --quiet main
  git -C "${d}" add -- scripts/blob.dat scripts/late.dat
  git -C "${d}" commit --quiet --message 'add blob'
  git -C "${d}" switch --quiet fix
  git -C "${d}" merge --quiet main
  beta_fixed "${d}"
  run_case sweep-binary-and-name "${d}" 1 \
    'sweep-uncovered: pair p1 term "Beta paragraph." hits docs/café.md:1-1 at the merge base (1-1 at head)'
  expect_absent 'blob.dat'
  expect_absent 'late.dat'

  # A line inserted right after an untouched twin does not move it.
  d="$(new_repo)"
  seed_files "${d}" scripts/ins.sh $'#!/usr/bin/env bash\n# Beta paragraph. Twin.\necho done'
  beta_fixed "${d}"
  sed -i '2a\# inserted' "${d}/scripts/ins.sh"
  commit_all "${d}" 'insert after twin'
  sweep_case "${d}" '["Beta paragraph."]' '[]' scripts/ins.sh
  run_case sweep-insert-after-twin "${d}" 1 \
    'hits scripts/ins.sh:2-2 at the merge base (2-2 at head) and no entry'

  # Attributes cannot hide a text file from the sweep: a committed
  # -diff, a binary macro in info/attributes and a core.attributesFile.
  d="$(new_repo)"
  seed_files "${d}" docs/h.md $'# H\n\nBeta paragraph. hidden twin.' .gitattributes 'docs/h.md -diff'
  beta_fixed "${d}"
  printf '*.md binary\n' >"${d}/.git/info/attributes"
  printf 'docs/h.md -text\n' >"${d}/.git/extra-attributes"
  git -C "${d}" config core.attributesFile "${d}/.git/extra-attributes"
  run_case sweep-attributes-ignored "${d}" 1 \
    'sweep-uncovered: pair p1 term "Beta paragraph." hits docs/h.md:3-3 at the merge base'

  # A caller's submodule.recurse does not send the sweep into a
  # checked-out submodule, whose files the merge base does not hold.
  d="$(new_repo)"
  sub="$(mktemp -d -p "${SCRATCH}")"
  git -C "${sub}" init --quiet --initial-branch=main
  printf 'Beta paragraph. in the submodule\n' >"${sub}/f.md"
  git -C "${sub}" add f.md
  git -C "${sub}" -c user.email=t@example.invalid -c user.name=t commit --quiet --message sub
  git -C "${d}" switch --quiet main
  git -C "${d}" -c protocol.file.allow=always submodule --quiet add "${sub}" subm
  git -C "${d}" commit --quiet --message 'add submodule'
  git -C "${d}" switch --quiet fix
  git -C "${d}" merge --quiet main
  git -C "${d}" -c protocol.file.allow=always submodule --quiet update --init
  seed_files "${d}" docs/e.md $'# E\n\nBeta paragraph. outside.'
  beta_fixed "${d}"
  git -C "${d}" config submodule.recurse true
  run_case sweep-submodule-recurse "${d}" 1 'hits docs/e.md:3-3 at the merge base'
  expect_absent 'subm'

  # A file name holding a tab cannot be read back from the hit list.
  d="$(new_repo)"
  seed_files "${d}" $'docs/t\tb.md' 'Beta paragraph. tabbed name'
  beta_fixed "${d}"
  run_case sweep-tab-name "${d}" 2 \
    'cannot sweep docs/t?b.md: its name holds a tab, newline, 0x01 or 0x02 byte (shown as ?); rename it'
  # So does one holding a byte the hit list uses to carry a tab or newline.
  d="$(new_repo)"
  seed_files "${d}" $'docs/c\001d.md' 'Beta paragraph. control name'
  beta_fixed "${d}"
  run_case sweep-control-name "${d}" 2 \
    'cannot sweep docs/c?d.md: its name holds a tab, newline, 0x01 or 0x02 byte (shown as ?); rename it'

  # finding groups pairs for missing-sweep, so it must be a whole number
  # of 1 or more: missing, null or a string would merge or split groups.
  d="$(new_repo)"
  beta_fixed "${d}"
  jq '.pairs[0] |= del(.finding)' "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case sweep-finding-missing "${d}" 1 \
    'schema: pair p1 needs a finding number (a whole number of 1 or more), got null'
  jq '.pairs[0].finding = "1"' "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case sweep-finding-string "${d}" 1 \
    'schema: pair p1 needs a finding number (a whole number of 1 or more), got "1"'
  jq '.pairs[0].finding = 1.5' "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case sweep-finding-fraction "${d}" 1 \
    'schema: pair p1 needs a finding number (a whole number of 1 or more), got 1.5'

  # Schema: a sweep that is not a list, an empty list, or a term that is
  # blank, holds a newline or is not a string.
  d="$(new_repo)"
  beta_fixed "${d}"
  sweep_case "${d}" '"Beta paragraph."'
  run_case sweep-not-list "${d}" 1 'schema: pair p1 sweep must be a list of terms, got "Beta paragraph."'
  sweep_case "${d}" '[]'
  run_case sweep-empty-list "${d}" 1 'schema: pair p1 sweep is an empty list; omit the field or name a term'
  sweep_case "${d}" '["Beta paragraph.", " \u200b", "a\nb", 3, "Beta\u0000 paragraph."]'
  run_case sweep-bad-terms "${d}" 1 \
    'schema: pair p1 sweep[1] needs a non-blank term with no newline, tab, CR or NUL, got " '
  also_expect 'schema: pair p1 sweep[2] needs a non-blank term with no newline, tab, CR or NUL, got "a<LF>b"'
  also_expect 'schema: pair p1 sweep[3] needs a non-blank term with no newline, tab, CR or NUL, got 3'
  also_expect 'schema: pair p1 sweep[4] needs a non-blank term with no newline, tab, CR or NUL, got "Beta<NUL> paragraph."'
  expect_absent 'sweep[0]'

  # Every finding needs a pair carrying a term; another pair of the same
  # finding may go without.
  d="$(new_repo)"
  sed -i -e 's/^Beta paragraph\.$/Beta paragraph, corrected./' \
    -e 's/^Gamma paragraph\.$/Gamma paragraph, corrected./' "${d}/docs/a.md"
  commit_all "${d}" 'fix beta and gamma'
  jq -n '{report: "r.md", code_changes: [], pairs: [
    {id: "p1", finding: 1, file: "docs/a.md", lines: "6-6", anchor: "Beta paragraph, corrected",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct",
      sweep: ["Beta paragraph."], siblings: []},
    {id: "p2", finding: 2, file: "docs/a.md", lines: "12-12", anchor: "Gamma paragraph, corrected",
      artifact: [{file: "scripts/tool.sh", lines: "1-5"}], fix_shape: "correct", siblings: []}]}' \
    >"${d}/ledger.json"
  gate_all "${d}"
  run_case sweep-missing-for-finding "${d}" 1 \
    'missing-sweep: finding 2 has no pair carrying a sweep term (pairs p2 at docs/a.md:12-12)'
  jq '.pairs[1].finding = 1' "${d}/ledger.json" >"${d}/l" && mv -- "${d}/l" "${d}/ledger.json"
  run_case sweep-shared-finding "${d}" 0 '' \
    'OK — 2 pairs; 2 hunks covered, 0 reflow-only and 0 generated skipped; 0 code changes; 0 changed, 0 unchanged and 0 removed siblings; 1 sweep terms, 1 hits cleared'
  d="$(new_repo)"
  beta_fixed "${d}"
  sweep_case "${d}" omit
  run_case sweep-omitted "${d}" 1 \
    'missing-sweep: finding 1 has no pair carrying a sweep term (pairs p1 at docs/a.md:6-6)'

  # --sweep prints each hit at the merge base, and reads a term after
  # "--" even when it starts with a dash.
  d="$(new_repo)"
  seed_files "${d}" docs/b.md $'# B\n\n-flag Beta paragraph. Twin.\n\n-x only here'
  run_sweep_case sweep-mode-hits "${d}" 0 '' 'docs/b.md:3-3: -flag Beta paragraph. Twin.' \
    --sweep 'Beta paragraph.'
  also_expect_stdout 'docs/a.md:6-6: Beta paragraph.'
  run_sweep_case sweep-mode-dash-term "${d}" 0 '' 'docs/b.md:5-5: -x only here' \
    --sweep -- '-x only'
  seed_files "${d}" scripts/tabs.sh $'\tBeta tabbed line\t\t'
  run_sweep_case sweep-mode-edge-tabs "${d}" 0 '' $'scripts/tabs.sh:1-1: \tBeta tabbed line\t\t' \
    --sweep 'Beta tabbed'
  # A hit spanning a wrap prints its first line.
  seed_files "${d}" docs/w.md $'# W\n\nWrapped Beta\nsweep line here'
  run_sweep_case sweep-mode-wrapped-hit "${d}" 0 '' 'docs/w.md:3-4: Wrapped Beta' \
    --sweep 'Beta sweep'
  expect_absent_stdout 'sweep line here'
  expect_absent_stdout 'docs/a.md'
  run_sweep_case sweep-mode-no-hit "${d}" 1 \
    'check-fix-ledger: term "Nowhere text" matches nothing in the sweep scope at the merge base' '' \
    --sweep 'Nowhere text'
  run_sweep_case sweep-mode-blank-term "${d}" 2 'bad sweep term: " "' '' --sweep ' '
  run_sweep_case sweep-mode-no-terms "${d}" 2 'usage: --sweep <term>...' '' --sweep
  run_sweep_case sweep-mode-with-hash "${d}" 2 '--sweep and --hash cannot be combined' '' \
    --sweep --hash docs/a.md 1-1

  # A base that does not resolve, or shares no history, stops the run
  # (merge_base, which ledger mode calls too).
  run_sweep_case sweep-mode-bad-base "${d}" 2 'base revision does not resolve: nosuch' '' \
    --base nosuch --sweep 'Beta paragraph.'
  git -C "${d}" switch --quiet --orphan lone
  git -C "${d}" commit --quiet --allow-empty --message lone
  run_sweep_case sweep-mode-no-merge-base "${d}" 2 'no merge base for main and HEAD' '' \
    --sweep 'Beta paragraph.'

  harness_assert_verify || failures=$((failures + 1))
  if ((failures > 0)); then
    printf '%d scenario(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf 'all scenarios passed\n'
}

main "$@"
