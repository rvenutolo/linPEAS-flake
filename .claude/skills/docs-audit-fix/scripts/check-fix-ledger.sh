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
  [[ ${positional[1]} =~ ^([1-9][0-9]{0,5})-([1-9][0-9]{0,5})$ ]] || die "bad range: ${positional[1]}"
  hash_start="${BASH_REMATCH[1]}"
  hash_end="${BASH_REMATCH[2]}"
  ((hash_start >= 1 && hash_start <= hash_end)) ||
    die "bad range: ${positional[1]} (start must be >= 1 and <= end)"
  git cat-file -e "${HEAD_REV}:${positional[0]}" 2>/dev/null ||
    die "not tracked at ${HEAD_REV}: ${positional[0]}"
  [[ "$(git cat-file -t "${HEAD_REV}:${positional[0]}")" == blob ]] ||
    die "not a file at ${HEAD_REV}: ${positional[0]}"
  block_hash "${HEAD_REV}" "${positional[0]}" "${hash_start}" "${hash_end}"
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
    def rng: str and test("^[1-9][0-9]{0,5}-[1-9][0-9]{0,5}$");
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
    if [[ "$(git cat-file -t "${HEAD_REV}:${file}")" != blob ]]; then
      finding artifact "pair ${id} ${file} is not a file at the head revision"
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

HUNKS_COVERED=0
HUNKS_REFLOW=0
HUNKS_GENERATED=0
ALL_HUNKS=''

# @description Unified-zero hunks between the merge base and head, as
# "file\tos\tol\tns\tnl". Paths come from the "+++ b/" header, read from
# column 7 so a space in a filename survives; a deletion ("+++ /dev/null")
# yields no rows, and deleted files are handled per file instead. Under
# --unified=0, every line after an "@@" header is a body line ("-" or
# "+") until exactly ol+nl of them have gone by, so that many lines are
# consumed unconditionally before another header is recognised — a body
# line that itself starts with "+++ " or "@@ " (e.g. an added line that
# happens to read "++ b/CHANGELOG.md") cannot pose as one.
function list_hunks() {
  git -c core.quotePath=false diff --no-color --no-renames --unified=0 "${MB}" "${HEAD_REV}" -- "$@" |
    awk '
      remaining > 0 { remaining--; next }
      /^\+\+\+ / {
        f = ($0 == "+++ /dev/null") ? "" : substr($0, 7)
        sub(/\t$/, "", f) # git appends a tab to a header path holding a space
        next
      }
      /^@@ / && f != "" {
        split(substr($2, 2), o, ","); split(substr($3, 2), n, ",")
        ol = (2 in o) ? o[2] : 1; nl = (2 in n) ? n[2] : 1
        print f "\t" o[1] "\t" ol "\t" n[1] "\t" nl
        remaining = ol + nl
      }'
}

# @description "start end name" line triples of BEGIN/END generated blocks
# in stdin, markers inclusive. An END only closes the block when its name
# matches the open BEGIN; a mismatched name leaves the BEGIN unterminated,
# so nothing between them counts as generated.
function generated_ranges() {
  awk '
    /^[[:space:]]*<!-- BEGIN [A-Za-z0-9_-]+ -->[[:space:]]*$/ {
      name = $0
      sub(/^[[:space:]]*<!-- BEGIN /, "", name)
      sub(/ -->[[:space:]]*$/, "", name)
      s = NR; sname = name
      next
    }
    /^[[:space:]]*<!-- END [A-Za-z0-9_-]+ -->[[:space:]]*$/ {
      name = $0
      sub(/^[[:space:]]*<!-- END /, "", name)
      sub(/ -->[[:space:]]*$/, "", name)
      if (s && name == sname) { print s, NR, sname; s = 0 }
    }'
}

# @description True when the old block around the hunk and the new block
# around it hold the same words in the same order — a re-wrap. False
# (rather than a garbage compare) when either side's span falls outside
# its file, which a hunk misattributed to the wrong file can produce.
function is_reflow() {
  local -r file="$1" os="$2" ol="$3" ns="$4" nl="$5"
  git cat-file -e "${MB}:${file}" 2>/dev/null || return 1
  local mb_n hd_n
  mb_n="$(git show "${MB}:${file}" | awk 'END { print NR }')"
  hd_n="$(git show "${HEAD_REV}:${file}" | awk 'END { print NR }')"
  local oe=$((os + (ol > 0 ? ol - 1 : 0))) ne=$((ns + (nl > 0 ? nl - 1 : 0)))
  ((os >= 1 && oe <= mb_n && ns >= 1 && ne <= hd_n)) || return 1
  local ospan nspan old new
  ospan="$(git show "${MB}:${file}" | block_span "$((os > 0 ? os : 1))" "$((oe > 0 ? oe : 1))")"
  nspan="$(git show "${HEAD_REV}:${file}" | block_span "$((ns > 0 ? ns : 1))" "$((ne > 0 ? ne : 1))")"
  old="$(git show "${MB}:${file}" | sed --quiet "${ospan% *},${ospan#* }p" | collapse)"
  new="$(git show "${HEAD_REV}:${file}" | sed --quiet "${nspan% *},${nspan#* }p" | collapse)"
  [[ ${old} == "${new}" ]]
}

# @description True when the hunk's old side sits inside a generated
# block at ${MB} and its new side sits inside a same-named generated
# block at HEAD. Checking only one side lets a writer forge the
# exemption by wrapping newly-changed prose in a fresh BEGIN/END pair
# that exists only at HEAD.
function hunk_is_generated() {
  local -r file="$1" os="$2" ol="$3" ns="$4" nl="$5"
  git cat-file -e "${MB}:${file}" 2>/dev/null || return 1
  local -r oe=$((os + (ol > 0 ? ol - 1 : 0))) ne=$((ns + (nl > 0 ? nl - 1 : 0)))
  local a b name oldname='' newname=''
  while IFS=' ' read -r a b name; do
    [[ -n ${a} ]] || continue
    # A pure insertion (ol==0) has no real old-side range: os is the
    # line BEFORE the insertion point, so it must sit strictly before
    # the END marker (os < b) — an insertion immediately after an
    # existing END is not "inside" that block just because os lands on
    # the END's own line number.
    if ((ol == 0)); then
      if ((os >= a && os < b)); then
        oldname="${name}"
        break
      fi
    elif ((os >= a && oe <= b)); then
      oldname="${name}"
      break
    fi
  done < <(git show "${MB}:${file}" | generated_ranges)
  [[ -n ${oldname} ]] || return 1
  while IFS=' ' read -r a b name; do
    [[ -n ${a} ]] || continue
    if ((nl == 0)); then
      if ((ns >= a && ns < b)); then
        newname="${name}"
        break
      fi
    elif ((ns >= a && ne <= b)); then
      newname="${name}"
      break
    fi
  done < <(git show "${HEAD_REV}:${file}" | generated_ranges)
  [[ -n ${newname} && ${newname} == "${oldname}" ]]
}

# @description Maximal non-blank runs of the line range $2..$3 of file
# $1 at HEAD, split at any blank line inside that range, as "start end"
# per run. A run is not extended past $2 or $3 into unchanged context —
# e.g. a fixed marker line the hunk merely abuts — only the hunk's own
# range is split.
function new_side_blocks() {
  local -r file="$1" ns="$2" ne="$3"
  git show "${HEAD_REV}:${file}" | awk -v ns="${ns}" -v ne="${ne}" '
    { blank[NR] = ($0 ~ /^[[:space:]]*$/) }
    END {
      a = 0
      for (i = ns; i <= ne + 1; i++) {
        isblank = (i > ne) ? 1 : blank[i]
        if (!isblank) {
          if (a == 0) a = i
        } else if (a != 0) {
          print a, i - 1
          a = 0
        }
      }
    }'
}

function check_completeness() {
  local file os ol ns nl hs he ne pf pa pb covered block_a block_b bcov all_covered block_count
  # Pair spans at head, as "file\ta\tb". Each pair's own range must also
  # fall inside its file, the same bound check check_artifacts runs for
  # each artifact.
  local spans='' id pfile plines span flen pstart pend
  while IFS=$'\t' read -r id pfile plines; do
    git cat-file -e "${HEAD_REV}:${pfile}" 2>/dev/null || {
      finding schema "pair ${id} file ${pfile} is not tracked at the head revision"
      continue
    }
    flen="$(git show "${HEAD_REV}:${pfile}" | awk 'END { print NR }')"
    pstart="${plines%-*}"
    pend="${plines#*-}"
    if ((pstart < 1 || pstart > pend || pend > flen)); then
      finding schema "pair ${id} ${pfile}:${plines} runs past end of file (${flen} lines)"
      continue
    fi
    span="$(git show "${HEAD_REV}:${pfile}" | block_span "${pstart}" "${pend}")"
    spans+="${pfile}"$'\t'"${span% *}"$'\t'"${span#* }"$'\n'
  done < <(jq --raw-output '.pairs[] | [.id, .file, .lines] | @tsv' "${LEDGER}")

  while IFS=$'\t' read -r file os ol ns nl; do
    [[ -n ${file} ]] || continue
    # A pure deletion has no new lines; it touches the boundary at ns/ns+1.
    hs=$((ns > 0 ? ns : 1))
    he=$((nl > 0 ? ns + nl - 1 : ns + 1))
    if hunk_is_generated "${file}" "${os}" "${ol}" "${ns}" "${nl}"; then
      HUNKS_GENERATED=$((HUNKS_GENERATED + 1))
      continue
    fi
    if is_reflow "${file}" "${os}" "${ol}" "${ns}" "${nl}"; then
      HUNKS_REFLOW=$((HUNKS_REFLOW + 1))
      continue
    fi
    if ((nl == 0)); then
      covered=0
      while IFS=$'\t' read -r pf pa pb; do
        [[ ${pf} == "${file}" ]] || continue
        if ((hs <= pb && he >= pa)); then
          covered=1
          break
        fi
      done <<<"${spans}"
      if ((covered)); then
        HUNKS_COVERED=$((HUNKS_COVERED + 1))
      else
        finding uncovered-hunk "${file}:${hs} changed and no pair covers it"
      fi
      continue
    fi
    # A hunk can touch more than one HEAD paragraph (e.g. an edit right
    # up against an inserted paragraph with no blank line recorded as
    # context between them); every such block needs its own pair.
    ne=$((ns + nl - 1))
    all_covered=1
    block_count=0
    while IFS=' ' read -r block_a block_b; do
      [[ -n ${block_a} ]] || continue
      block_count=$((block_count + 1))
      bcov=0
      while IFS=$'\t' read -r pf pa pb; do
        [[ ${pf} == "${file}" ]] || continue
        if ((block_a <= pb && block_b >= pa)); then
          bcov=1
          break
        fi
      done <<<"${spans}"
      if ((bcov == 0)); then
        all_covered=0
        finding uncovered-hunk "${file}:${block_a} changed and no pair covers it"
      fi
    done < <(new_side_blocks "${file}" "${ns}" "${ne}")
    if ((block_count == 0)); then
      # The new side is entirely blank/whitespace lines, so there is no
      # paragraph to split on; fall back to the same boundary check the
      # nl==0 path uses, rather than trusting all_covered's unproven
      # default of 1.
      covered=0
      while IFS=$'\t' read -r pf pa pb; do
        [[ ${pf} == "${file}" ]] || continue
        if ((hs <= pb && he >= pa)); then
          covered=1
          break
        fi
      done <<<"${spans}"
      if ((covered)); then
        HUNKS_COVERED=$((HUNKS_COVERED + 1))
      else
        finding uncovered-hunk "${file}:${hs} changed and no pair covers it"
      fi
    elif ((all_covered)); then
      HUNKS_COVERED=$((HUNKS_COVERED + 1))
    fi
  done < <(list_hunks '*.md' ':(exclude)CHANGELOG.md' ':(exclude)tests/fixtures')

  # Every changed file that is not a surviving, textually-diffed
  # Markdown file must be listed. --numstat (rather than --name-only)
  # also reports whether git treated the diff as binary ("-\t-" for
  # both counts) — a .md file with a NUL byte or a "-diff" attribute
  # produces no "+++"/"@@" headers at all, so list_hunks never sees it
  # and it must not be silently exempted the way a real text hunk is.
  local listed changed added deleted
  listed="$(jq --raw-output '.code_changes[].file' "${LEDGER}")"
  # shellcheck disable=SC2034 # named for numstat's fixed 3-column shape; only "added" (binary vs text) and "changed" are read
  while IFS=$'\t' read -r added deleted changed; do
    [[ -n ${changed} ]] || continue
    if [[ ${changed} == *.md && ${added} != '-' ]] &&
      git cat-file -e "${HEAD_REV}:${changed}" 2>/dev/null; then
      continue
    fi
    if ! grep --line-regexp --fixed-strings --quiet -- "${changed}" <<<"${listed}"; then
      if [[ ${added} == '-' ]]; then
        finding uncovered-file "${changed} is a binary diff and not listed in code_changes"
      else
        finding uncovered-file "${changed} is changed but not listed in code_changes"
      fi
    fi
  done < <(git -c core.quotePath=false diff --numstat --no-renames "${MB}" "${HEAD_REV}")

  # shellcheck disable=SC2034 # consumed by the sibling check a later task adds
  ALL_HUNKS="$(list_hunks .)"
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
    check_completeness
  fi
  if ((findings > 0)); then
    printf '%s: %d finding(s)\n' "${PROG}" "${findings}" >&2
    exit 1
  fi
  printf '%s: OK — %d pairs; %d hunks covered, %d reflow-only and %d generated skipped; %d code changes\n' \
    "${PROG}" "$(jq '.pairs | length' "${LEDGER}")" "${HUNKS_COVERED}" "${HUNKS_REFLOW}" "${HUNKS_GENERATED}" "$(jq '.code_changes | length' "${LEDGER}")"
}

main
