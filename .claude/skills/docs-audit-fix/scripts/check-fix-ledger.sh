#!/usr/bin/env bash
# .claude/skills/docs-audit-fix/scripts/check-fix-ledger.sh
#
# @description Pre-PR gate for a docs-audit fix pass. The writer records,
# per rewritten paragraph, the artifact range the new sentence was written
# against and the sibling set it belongs to; a separate gate agent records
# a verdict and the hash of the paragraph it read. This script proves the
# record covers the branch's diff and still describes it:
#
#   completeness  every changed Markdown hunk outside generated blocks and
#                 pure reflow overlaps a recorded paragraph, and every other
#                 changed file is listed as a code change
#   artifacts     every recorded artifact range exists at the head revision
#   siblings      an unchanged sibling carries a reason; a changed one
#                 overlaps a hunk
#   verdicts      every pair is gated TRUE against its current text, and
#                 every code change carries the gate's adversarial attack
#
# A paragraph is the blank-line-delimited block around the recorded lines,
# and its hash covers that whole block with whitespace collapsed, so a
# re-wrap or a shift in line numbers leaves a verdict current while any
# word change inside the block makes it stale.
#
# Usage:
#   check-fix-ledger.sh [--base <rev>] [--head <rev>] <ledger.json> <gate.json>
#   check-fix-ledger.sh [--head <rev>] --hash <file> <start>-<end>
#
# Exit codes:
#   0  the ledger covers the diff and every pair is currently gated TRUE
#   1  findings (printed to stderr, one line each)
#   2  the check could not run: missing tool, bad arguments, unparsable
#      JSON, unresolvable revision, or uncommitted tracked changes

set -Eeuo pipefail
IFS=$'\n\t'

readonly PROG='check-fix-ledger'
findings=0

function die() {
  printf '%s: %s\n' "${PROG}" "$1" >&2
  exit 2
}

function finding() {
  printf '%s: %s: %s\n' "${PROG}" "$1" "$2" >&2
  findings=$((findings + 1))
}

for tool in git jq awk sed sha256sum tr cut realpath; do
  command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
done

function collapse() {
  tr --squeeze-repeats '[:space:]' ' ' | sed --expression 's/^ //' --expression 's/ $//'
}

# @description Print "<a> <b>": the blank-line-delimited block(s) that
# contain lines $1..$2 of stdin.
function block_span() {
  awk -v s="$1" -v e="$2" '
    { blank[NR] = ($0 ~ /^[[:space:]]*$/) }
    END {
      a = s; while (a > 1 && !blank[a - 1]) a--
      b = e; while (b < NR && !blank[b + 1]) b++
      print a, b
    }'
}

function block_hash() {
  local -r rev="$1" file="$2" start="$3" end="$4"
  local span a b
  span="$(git show "${rev}:${file}" | block_span "${start}" "${end}")"
  a="${span% *}"
  b="${span#* }"
  git show "${rev}:${file}" | sed --quiet "${a},${b}p" | collapse |
    sha256sum | cut --delimiter=' ' --fields=1
}

BASE='main'
HEAD_REV='HEAD'
hash_mode=0
positional=()
while (($# > 0)); do
  case "$1" in
  --base)
    (($# >= 2)) || die '--base needs a revision'
    BASE="$2"
    shift 2
    ;;
  --head)
    (($# >= 2)) || die '--head needs a revision'
    HEAD_REV="$2"
    shift 2
    ;;
  --hash)
    hash_mode=1
    shift
    ;;
  -*) die "unknown option: $1" ;;
  *)
    positional+=("$1")
    shift
    ;;
  esac
done
readonly BASE HEAD_REV

git rev-parse --verify --quiet "${HEAD_REV}^{commit}" >/dev/null ||
  die "head revision does not resolve: ${HEAD_REV}"

if ((hash_mode)); then
  ((${#positional[@]} == 2)) || die 'usage: --hash <file> <start>-<end>'
  [[ ${positional[1]} =~ ^([0-9]+)-([0-9]+)$ ]] || die "bad range: ${positional[1]}"
  git cat-file -e "${HEAD_REV}:${positional[0]}" 2>/dev/null ||
    die "not tracked at ${HEAD_REV}: ${positional[0]}"
  block_hash "${HEAD_REV}" "${positional[0]}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  exit 0
fi

((${#positional[@]} == 2)) || die 'usage: [--base <rev>] [--head <rev>] <ledger.json> <gate.json>'
# Resolve both paths before moving to the repo root, so pathspecs in the
# diffs below mean the same thing from any working directory.
LEDGER="$(realpath -- "${positional[0]}")" || die "cannot resolve ${positional[0]}"
GATE="$(realpath -- "${positional[1]}")" || die "cannot resolve ${positional[1]}"
readonly LEDGER GATE
cd -- "$(git rev-parse --show-toplevel)" || die 'not inside a git work tree'
jq --exit-status 'type == "object"' "${LEDGER}" >/dev/null 2>&1 ||
  die "${LEDGER} is not valid JSON"
jq --exit-status 'type == "object"' "${GATE}" >/dev/null 2>&1 ||
  die "${GATE} is not valid JSON"
git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null ||
  die "base revision does not resolve: ${BASE}"
MB="$(git merge-base "${BASE}" "${HEAD_REV}")" || die "no merge base for ${BASE} and ${HEAD_REV}"
# shellcheck disable=SC2034 # consumed by the diff-scoping checks a later task adds
readonly MB

# Checking HEAD with edits still in the working tree would pass or fail a
# commit the writer is no longer looking at.
if [[ ${HEAD_REV} == HEAD && -n "$(git status --porcelain --untracked-files=no)" ]]; then
  die 'uncommitted changes to tracked files; commit them before checking'
fi

# @description Schema and enum findings. Each line is "<class>\t<detail>".
function check_schema() {
  jq --raw-output '
    def str: type == "string" and length > 0;
    def rng: str and test("^[0-9]+-[0-9]+$");
    (if (.pairs | type) != "array" then ["schema", "ledger needs a pairs array"] else empty end),
    (if (.code_changes | type) != "array" then ["schema", "ledger needs a code_changes array"] else empty end),
    ((.pairs // [])[] | (.id // "?") as $id |
      (if (.id | str) and (.file | str) and (.lines | rng) then empty
      else ["schema", "pair \($id) needs id, file and a <start>-<end> lines"] end),
      (if (.artifact | type) == "array" and (.artifact | length) > 0
          and all(.artifact[]; (.file | str) and (.lines | rng)) then empty
      else ["schema", "pair \($id) needs a non-empty artifact list of file and lines"] end),
      (if (.siblings | type) == "array" and all(.siblings[]; .file | str) then empty
      else ["schema", "pair \($id) needs a siblings list whose members name a file"] end),
      (if .fix_shape == "drop" or .fix_shape == "scope" or .fix_shape == "correct" then empty
      else ["enum", "pair \($id) fix_shape \(.fix_shape | tojson) is not drop, scope or correct"] end)),
    ([(.pairs // [])[].id] | group_by(.)[] | select(length > 1)
      | ["schema", "pair id \(.[0]) is used more than once"]),
    ((.code_changes // [])[] | select((.file | str) | not)
      | ["schema", "a code_changes entry needs a file"])
    | @tsv' "${LEDGER}"
}

# @description Each artifact must be tracked at head with its range inside
# the file.
function check_artifacts() {
  local id file lines start end n
  while IFS=$'\t' read -r id file lines; do
    if ! git cat-file -e "${HEAD_REV}:${file}" 2>/dev/null; then
      finding artifact "pair ${id} ${file} is not tracked at the head revision"
      continue
    fi
    start="${lines%-*}"
    end="${lines#*-}"
    n="$(git show "${HEAD_REV}:${file}" | awk 'END { print NR }')"
    if ((start < 1 || start > end || end > n)); then
      finding artifact "pair ${id} ${file}:${lines} runs past end of file (${n} lines)"
    fi
  done < <(jq --raw-output '.pairs[] | .id as $id | .artifact[] | [$id, .file, .lines] | @tsv' "${LEDGER}")
}

function main() {
  local class detail schema_bad=0
  while IFS=$'\t' read -r class detail; do
    [[ -n ${class} ]] || continue
    finding "${class}" "${detail}"
    [[ ${class} == schema ]] && schema_bad=1
  done < <(check_schema)
  # Later checks read the ledger's shape; a schema finding stops here.
  if ((schema_bad == 0)); then
    check_artifacts
  fi
  if ((findings > 0)); then
    printf '%s: %d finding(s)\n' "${PROG}" "${findings}" >&2
    exit 1
  fi
  printf '%s: OK — %d pairs; %d hunks covered, %d reflow-only and %d generated skipped; %d code changes\n' \
    "${PROG}" "$(jq '.pairs | length' "${LEDGER}")" 1 0 0 "$(jq '.code_changes | length' "${LEDGER}")"
}

main
