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
# Under a UTF-8 locale bash's [0-9] also matches non-ASCII digits (which
# the (( )) bound checks then fail on as an arithmetic error that `if`
# reads as false), and awk's [[:space:]] also matches non-ASCII spaces,
# so a paragraph's block span, and with it the gate's hash, would depend
# on the caller's locale. The C locale pins all of it to ASCII.
export LC_ALL=C
# The caller's environment must not change what git diffs:
# GIT_DIFF_OPTS=--unified=N overrides --unified=0; the *_PATHSPECS
# switches turn "*.md" into a literal name (or change its matching) so
# every Markdown hunk disappears; and a replace ref could map a changed
# blob back to its base text.
unset GIT_DIFF_OPTS GIT_GLOB_PATHSPECS GIT_LITERAL_PATHSPECS \
  GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS
export GIT_NO_REPLACE_OBJECTS=1

readonly PROG='check-fix-ledger'
findings=0
# Findings per class, for the summary line.
declare -A class_count=()

function die() {
  printf '%s: %s\n' "${PROG}" "$1" >&2
  exit 2
}

function finding() {
  printf '%s: %s: %s\n' "${PROG}" "$1" "$2" >&2
  findings=$((findings + 1))
  class_count["$1"]=$((${class_count["$1"]:-0} + 1))
}

for tool in git jq awk sed sha256sum tr cut realpath; do
  command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
done

function collapse() {
  tr --squeeze-repeats '[:space:]' ' ' | sed --expression 's/^ //' --expression 's/ $//'
}

# @description True when $1 is exactly a "<start>-<end>" range with each
# number 1-6 digits. Re-checked in bash at every point a range read from
# jq's @tsv output feeds an arithmetic ((...)) expression: jq's own rng
# check (in check_schema) can pass a value carrying a trailing newline
# that @tsv then emits literally, and a bash arithmetic error on that
# stray newline is read by `if` as false rather than raised — silently
# skipping the bound check it guards.
function valid_range() {
  [[ $1 =~ ^[1-9][0-9]{0,5}-[1-9][0-9]{0,5}$ ]]
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
  hash_n="$(git show "${HEAD_REV}:${positional[0]}" | awk 'END { print NR }')"
  ((hash_end <= hash_n)) ||
    die "bad range: ${positional[1]} (end must be <= ${hash_n} lines)"
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
# jq's exit status reflects only its last input: a file holding a stray
# document before the object (or two appended objects) would pass an
# object check, and every later read would then error on, or merge, the
# extra document with no failing status for `|| die` to catch. Each file
# must parse, then hold exactly one top-level object.
for json_file in "${LEDGER}" "${GATE}"; do
  jq empty "${json_file}" >/dev/null 2>&1 || die "${json_file} is not valid JSON"
  jq --exit-status --slurp 'length == 1 and (.[0] | type) == "object"' \
    "${json_file}" >/dev/null 2>&1 ||
    die "${json_file} does not hold exactly one JSON object"
done
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
# Every list is read through `arr` and every element is type-checked
# before anything indexes it: a string or number where an object belongs
# would otherwise raise a jq error mid-stream, and every finding after
# that point (an enum, a duplicate id, a newline in a file name) would be
# lost. The callers capture this output with `|| die`, so a jq failure
# the guards miss stops the run instead of reading as no findings.
function check_schema() {
  jq --raw-output '
    def str: type == "string" and length > 0;
    # test() with $ matches before a trailing newline (Oniguruma), so
    # "1-999999\n" would otherwise pass; the explicit no-newline check
    # closes that regardless of anchor semantics.
    def rng: str and (test("\n") | not) and test("^[1-9][0-9]{0,5}-[1-9][0-9]{0,5}$");
    def ctl: type == "string" and test("[\n\t\r]");
    def shown: gsub("\n"; "<LF>") | gsub("\t"; "<TAB>") | gsub("\r"; "<CR>");
    def arr: if type == "array" then . else [] end;
    def nonobj($what): arr | to_entries[] | select(.value | type != "object")
      | ["schema", "\($what)[\(.key)] is not an object"];
    (if (.pairs | type) != "array" then ["schema", "ledger needs a pairs array"] else empty end),
    (if (.code_changes | type) != "array" then ["schema", "ledger needs a code_changes array"] else empty end),
    (.pairs | nonobj("pairs")),
    (.code_changes | nonobj("code_changes")),
    ((.pairs | arr)[] | objects | (.id // "?") as $id |
      (if (.id | str) and (.file | str) and (.lines | rng) then empty
      else ["schema", "pair \($id) needs id, file and a <start>-<end> lines"] end),
      (.artifact | nonobj("pair \($id) artifact")),
      (if (.artifact | type) == "array" and (.artifact | length) > 0
          and all(.artifact[] | objects; (.file | str) and (.lines | rng)) then empty
      else ["schema", "pair \($id) needs a non-empty artifact list of file and lines"] end),
      (.siblings | nonobj("pair \($id) siblings")),
      (if (.siblings | type) == "array" and all(.siblings[] | objects; .file | str) then empty
      else ["schema", "pair \($id) needs a siblings list whose members name a file"] end),
      (if .fix_shape == "drop" or .fix_shape == "scope" or .fix_shape == "correct" then empty
      else ["enum", "pair \($id) fix_shape \(.fix_shape | tojson) is not drop, scope or correct"] end),
      ((.siblings | arr)[] | objects | select(.status != "changed" and .status != "unchanged")
        | ["enum", "pair \($id) sibling \(.file) status \(.status | tojson) is not changed or unchanged"])),
    ([(.pairs | arr)[] | objects | .id] | group_by(.)[] | select(length > 1)
      | ["schema", "pair id \(.[0]) is used more than once"]),
    ((.code_changes | arr)[] | objects | select((.file | str) | not)
      | ["schema", "a code_changes entry needs a file"]),
    # File names are later read one per line (or one per tab field), so
    # a newline, tab or CR inside one would split it into extra names,
    # e.g. listing a changed file no entry actually names. The name is
    # shown with those characters spelled out, since @tsv would escape
    # a JSON rendering a second time.
    ((.code_changes | arr)[] | objects | select(.file | ctl)
      | ["schema", "code_changes file \"\(.file | shown)\" holds a newline, tab or CR"]),
    ((.pairs | arr)[] | objects | (.id // "?") as $id |
      (select(.file | ctl)
        | ["schema", "pair \($id) file \"\(.file | shown)\" holds a newline, tab or CR"]),
      ((.artifact | arr)[] | objects | select(.file | ctl)
        | ["schema", "pair \($id) artifact file \"\(.file | shown)\" holds a newline, tab or CR"]),
      ((.siblings | arr)[] | objects | select(.file | ctl)
        | ["schema", "pair \($id) sibling file \"\(.file | shown)\" holds a newline, tab or CR"]))
    | @tsv' "${LEDGER}"
}

# @description Gate schema findings, in check_schema's format. The gate's
# pairs and code_changes lists must hold objects, so the verdict checks
# that read them never index a string or number. Each verdict id must be
# unique (with two, which one counts would depend on order) and must name
# a ledger pair (a verdict for no pair gates nothing, and usually means
# the gate read a different ledger).
function check_gate_schema() {
  jq --raw-output --slurpfile ledger "${LEDGER}" '
    def arr: if type == "array" then . else [] end;
    def nonobj($what): arr | to_entries[] | select(.value | type != "object")
      | ["schema", "gate \($what)[\(.key)] is not an object"];
    ([$ledger[0].pairs | arr | .[] | objects | .id]) as $ids |
    (if (.pairs | type) != "array" then ["schema", "gate needs a pairs array"] else empty end),
    (if (.code_changes | type) != "array" then ["schema", "gate needs a code_changes array"] else empty end),
    (.pairs | nonobj("pairs")),
    (.code_changes | nonobj("code_changes")),
    ([(.pairs | arr)[] | objects | .id] | group_by(.)[] | select(length > 1)
      | ["schema", "gate verdict id \(.[0]) is used more than once"]),
    ((.pairs | arr)[] | objects | .id as $id | select(any($ids[]; . == $id) | not)
      | ["schema", "gate verdict id \($id) is not a ledger pair"]),
    ((.pairs | arr)[] | objects
      | select(.verdict != "TRUE" and .verdict != "FALSE" and .verdict != "OVERREACHES")
      | ["enum", "verdict for pair \(.id) \(.verdict | tojson) is not TRUE, FALSE or OVERREACHES"])
    | @tsv' "${GATE}"
}

# @description Each artifact must be tracked at head with its range inside
# the file.
function check_artifacts() {
  local id file lines start end n records
  records="$(jq --raw-output '.pairs[] | .id as $id | .artifact[] | [$id, .file, .lines] | @tsv' "${LEDGER}")" ||
    die "could not read the artifact list from ${LEDGER}"
  while IFS=$'\t' read -r id file lines; do
    [[ -n ${id} ]] || continue
    if ! git cat-file -e "${HEAD_REV}:${file}" 2>/dev/null; then
      finding artifact "pair ${id} ${file} is not tracked at the head revision"
      continue
    fi
    if [[ "$(git cat-file -t "${HEAD_REV}:${file}")" != blob ]]; then
      finding artifact "pair ${id} ${file} is not a file at the head revision"
      continue
    fi
    if ! valid_range "${lines}"; then
      finding schema "pair ${id} artifact ${file}:${lines} is not a valid <start>-<end> range"
      continue
    fi
    start="${lines%-*}"
    end="${lines#*-}"
    n="$(git show "${HEAD_REV}:${file}" | awk 'END { print NR }')"
    if ((start < 1 || start > end || end > n)); then
      finding artifact "pair ${id} ${file}:${lines} runs past end of file (${n} lines)"
    fi
  done <<<"${records}"
}

HUNKS_COVERED=0
HUNKS_REFLOW=0
HUNKS_GENERATED=0
SIBLINGS_CHANGED=0
SIBLINGS_UNCHANGED=0
ALL_HUNKS=''

# @description Unified-zero hunks between the merge base and head, as
# "file\tos\tol\tns\tnl". Paths come from the "+++ b/" header, read from
# column 7 so a space in a filename survives; a deletion ("+++ /dev/null")
# yields no rows, and deleted files are handled per file instead.
#
# After an "@@" header the body is consumed by prefix: a "-" line counts
# against ol, a "+" line against nl, a " " context line against both, and
# a "\ No newline at end of file" line against neither. Another header is
# recognised only once both counts reach 0, so a body line that itself
# starts with "+++ " or "@@ " (e.g. an added line that happens to read
# "++ b/CHANGELOG.md") cannot pose as one. A line with any other prefix
# while counts remain, a prefix whose count is already spent, or a diff
# that ends mid-hunk is a parse error: awk exits 2, which the callers
# turn into die. Counting per prefix rather than skipping ol+nl lines
# keeps a hunk that does carry context from over-skipping into, and
# hiding, the next file's headers.
#
# --unified=0 with --inter-hunk-context=0 (and GIT_DIFF_OPTS, unset at
# script start) keeps git from emitting context at all:
# diff.interHunkContext would merge nearby hunks with context between
# them. --no-ext-diff and --no-textconv stop a
# repo-local diff.external command or a per-path textconv driver from
# replacing the real diff with attacker-controlled (or merely
# misleading) output; --text forces even a file git would otherwise call
# binary (a NUL byte, a "-diff" attribute) through the same line-oriented
# diff, so it gets real hunks instead of being silently skipped;
# --src-prefix/--dst-prefix pin the "a/"/"b/" header prefixes this
# parser's column-7 read relies on, regardless of a repo's diff.noprefix
# setting.
function list_hunks() {
  git -c core.quotePath=false diff --no-ext-diff \
    --no-textconv --text --src-prefix=a/ --dst-prefix=b/ --no-color \
    --no-renames --unified=0 --inter-hunk-context=0 \
    "${MB}" "${HEAD_REV}" -- "$@" |
    awk -v prog="${PROG}" '
      function bad(why) {
        printf "%s: unparsable diff line %d (%s): %s\n", prog, NR, why, $0 > "/dev/stderr"
        failed = 1
        exit 2
      }
      ro > 0 || rn > 0 {
        c = substr($0, 1, 1)
        if (c == "\\") next
        if (c == "-") { if (ro == 0) bad("removed line past the hunk count"); ro--; next }
        if (c == "+") { if (rn == 0) bad("added line past the hunk count"); rn--; next }
        if (c == " ") {
          if (ro == 0 || rn == 0) bad("context line past the hunk count")
          ro--; rn--; next
        }
        bad("unknown hunk body prefix")
      }
      /^\+\+\+ / {
        f = ($0 == "+++ /dev/null") ? "" : substr($0, 7)
        sub(/\t$/, "", f) # git appends a tab to a header path holding a space
        next
      }
      /^@@ / {
        split(substr($2, 2), o, ","); split(substr($3, 2), n, ",")
        ol = (2 in o) ? o[2] : 1; nl = (2 in n) ? n[2] : 1
        ro = ol + 0; rn = nl + 0
        if (f != "") print f "\t" o[1] "\t" ol "\t" n[1] "\t" nl
      }
      END { if (!failed && (ro > 0 || rn > 0)) bad("diff ends inside a hunk") }'
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

# @description True when every line $3..$4 of $1:$2 is empty or
# whitespace-only.
function all_blank() {
  local -r rev="$1" file="$2" start="$3" end="$4"
  ! git show "${rev}:${file}" | awk -v s="${start}" -v e="${end}" '
    NR >= s && NR <= e && $0 !~ /^[[:space:]]*$/ { bad = 1 }
    END { exit bad ? 0 : 1 }'
}

# @description True when the old block around the hunk and the new block
# around it hold the same words in the same order — a re-wrap. False
# (rather than a garbage compare) when either side's span falls outside
# its file, which a hunk misattributed to the wrong file can produce.
# A pure insertion or deletion (ol==0 or nl==0) is a re-wrap only when
# every added/removed line is blank; a blank-line anchor otherwise lets
# block_span expand across it and join the paragraphs on both sides, so
# a duplicated paragraph being inserted or deleted (or a duplicate
# wrapped differently) can collapse to the same text as its neighbour
# and read as a re-wrap even though real content was added or removed.
function is_reflow() {
  local -r file="$1" os="$2" ol="$3" ns="$4" nl="$5"
  git cat-file -e "${MB}:${file}" 2>/dev/null || return 1
  local mb_n hd_n
  mb_n="$(git show "${MB}:${file}" | awk 'END { print NR }')"
  hd_n="$(git show "${HEAD_REV}:${file}" | awk 'END { print NR }')"
  local oe=$((os + (ol > 0 ? ol - 1 : 0))) ne=$((ns + (nl > 0 ? nl - 1 : 0)))
  ((os >= 1 && oe <= mb_n && ns >= 1 && ne <= hd_n)) || return 1
  if ((ol == 0)) && ! all_blank "${HEAD_REV}" "${file}" "${ns}" "${ne}"; then
    return 1
  fi
  if ((nl == 0)) && ! all_blank "${MB}" "${file}" "${os}" "${oe}"; then
    return 1
  fi
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
  local md_hunks
  md_hunks="$(list_hunks '*.md' ':(exclude)CHANGELOG.md' ':(exclude)tests/fixtures')" ||
    die 'could not parse the Markdown diff'
  # Pair spans at head, as "file\ta\tb". Each pair's own range must also
  # fall inside its file, the same bound check check_artifacts runs for
  # each artifact.
  local spans='' id pfile plines span flen pstart pend records
  records="$(jq --raw-output '.pairs[] | [.id, .file, .lines] | @tsv' "${LEDGER}")" ||
    die "could not read the pair list from ${LEDGER}"
  while IFS=$'\t' read -r id pfile plines; do
    [[ -n ${id} ]] || continue
    git cat-file -e "${HEAD_REV}:${pfile}" 2>/dev/null || {
      finding schema "pair ${id} file ${pfile} is not tracked at the head revision"
      continue
    }
    if [[ "$(git cat-file -t "${HEAD_REV}:${pfile}")" != blob ]]; then
      finding schema "pair ${id} file ${pfile} is not a file at the head revision"
      continue
    fi
    if ! valid_range "${plines}"; then
      finding schema "pair ${id} ${pfile}:${plines} is not a valid <start>-<end> range"
      continue
    fi
    flen="$(git show "${HEAD_REV}:${pfile}" | awk 'END { print NR }')"
    pstart="${plines%-*}"
    pend="${plines#*-}"
    if ((pstart < 1 || pstart > pend || pend > flen)); then
      finding schema "pair ${id} ${pfile}:${plines} runs past end of file (${flen} lines)"
      continue
    fi
    span="$(git show "${HEAD_REV}:${pfile}" | block_span "${pstart}" "${pend}")"
    spans+="${pfile}"$'\t'"${span% *}"$'\t'"${span#* }"$'\n'
  done <<<"${records}"

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
  done <<<"${md_hunks}"

  # Every changed file that is not a surviving Markdown file must be
  # listed. list_hunks' --text now forces a hunk-level diff even for a
  # file git would call binary, so a surviving .md file's coverage is
  # enforced by the per-paragraph pairing above regardless of binary
  # status; this loop no longer needs to special-case binary itself
  # (round 2's numstat-based branch is dead now that --text is in
  # play, and re-checking --numstat here would just disagree with
  # list_hunks, which reads --text hunks).
  local listed changed changed_files
  listed="$(jq --raw-output '.code_changes[].file' "${LEDGER}")" ||
    die "could not read code_changes from ${LEDGER}"
  changed_files="$(git -c core.quotePath=false diff --no-ext-diff --no-textconv \
    --src-prefix=a/ --dst-prefix=b/ --name-only --no-renames "${MB}" "${HEAD_REV}")" ||
    die 'could not list the changed files'
  while IFS= read -r changed; do
    [[ -n ${changed} ]] || continue
    if [[ ${changed} == *.md ]] && git cat-file -e "${HEAD_REV}:${changed}" 2>/dev/null; then
      continue
    fi
    if ! grep --line-regexp --fixed-strings --quiet -- "${changed}" <<<"${listed}"; then
      finding uncovered-file "${changed} is changed but not listed in code_changes"
    fi
  done <<<"${changed_files}"

  ALL_HUNKS="$(list_hunks .)" || die 'could not parse the full diff'
}

# @description An unchanged sibling must carry a reason; a sibling marked
# changed must overlap a hunk of the branch diff by line range, not merely
# sit in a file that has a hunk somewhere. A missing lines, status or
# reason field is read as "-": tab is IFS whitespace, so an empty field
# would collapse and shift every field after it.
function check_siblings() {
  local id file lines status reason s e hf ns nl hs he hit records
  records="$(jq --raw-output '.pairs[] | .id as $id | .siblings[]
    | [$id, .file,
      (if (.lines | type) == "string" and (.lines | length) > 0 then .lines else "-" end),
      (if (.status | type) == "string" and (.status | length) > 0 then .status else "-" end),
      (if (.reason | type) == "string" and (.reason | length) > 0 then .reason else "-" end)]
    | @tsv' "${LEDGER}")" ||
    die "could not read the sibling list from ${LEDGER}"
  while IFS=$'\t' read -r id file lines status reason; do
    [[ -n ${id} ]] || continue
    if [[ ${status} == unchanged ]]; then
      if [[ ${reason} == - ]]; then
        finding sibling-reason "pair ${id} sibling ${file}:${lines} is unchanged with no reason"
      else
        SIBLINGS_UNCHANGED=$((SIBLINGS_UNCHANGED + 1))
      fi
      continue
    fi
    [[ ${status} == changed ]] || continue # check_schema reported the enum
    if ! valid_range "${lines}"; then
      finding schema "pair ${id} sibling ${file}:${lines} is marked changed without a valid <start>-<end> range"
      continue
    fi
    s="${lines%-*}"
    e="${lines#*-}"
    hit=0
    while IFS=$'\t' read -r hf _ _ ns nl; do
      [[ ${hf} == "${file}" ]] || continue
      # A pure deletion has no new lines; it touches the boundary at ns/ns+1.
      hs=$((ns > 0 ? ns : 1))
      he=$((nl > 0 ? ns + nl - 1 : ns + 1))
      if ((hs <= e && he >= s)); then
        hit=1
        break
      fi
    done <<<"${ALL_HUNKS}"
    if ((hit)); then
      SIBLINGS_CHANGED=$((SIBLINGS_CHANGED + 1))
    else
      finding sibling-not-changed "pair ${id} sibling ${file}:${lines} is marked changed but no hunk touches it"
    fi
  done <<<"${records}"
}

# @description Every pair needs a gate verdict of TRUE whose hash still
# matches the pair's whole block at head, and every code change needs a
# gate entry recording an attack and its result. A pair whose own file or
# range check_completeness already rejected is skipped here, since there
# is no block to hash. Missing verdict, hash or note fields are read as
# "-", for the same IFS reason check_siblings gives.
function check_verdicts() {
  local id file lines verdict hash note current n start end records
  records="$(jq --raw-output --slurpfile gate "${GATE}" '
    .pairs[] | .id as $id
    | ([$gate[0].pairs[] | select(.id == $id)] | first) as $v
    | [$id, .file, .lines,
      (if $v == null then "-" elif ($v.verdict | type) == "string" then $v.verdict
      else ($v.verdict | tojson) end),
      (if ($v.hash | type) == "string" and ($v.hash | length) > 0 then $v.hash else "-" end),
      (if ($v.note | type) == "string" and ($v.note | length) > 0 then $v.note else "-" end)]
    | @tsv' "${LEDGER}")" ||
    die "could not read the gate verdicts from ${GATE}"
  while IFS=$'\t' read -r id file lines verdict hash note; do
    [[ -n ${id} ]] || continue
    if [[ ${verdict} == - ]]; then
      finding missing-verdict "pair ${id} has no gate verdict"
      continue
    fi
    if [[ ${verdict} != TRUE ]]; then
      finding verdict "pair ${id} is ${verdict}: ${note}"
      continue
    fi
    git cat-file -e "${HEAD_REV}:${file}" 2>/dev/null || continue
    [[ "$(git cat-file -t "${HEAD_REV}:${file}")" == blob ]] || continue
    valid_range "${lines}" || continue
    start="${lines%-*}"
    end="${lines#*-}"
    n="$(git show "${HEAD_REV}:${file}" | awk 'END { print NR }')"
    ((start >= 1 && start <= end && end <= n)) || continue
    current="$(block_hash "${HEAD_REV}" "${file}" "${start}" "${end}")"
    [[ ${current} == "${hash}" ]] ||
      finding stale-verdict "pair ${id} ${file}:${lines} changed after the gate read it"
  done <<<"${records}"

  local cfile unattacked
  unattacked="$(jq --raw-output --slurpfile gate "${GATE}" '
    def str: type == "string" and length > 0;
    .code_changes[].file as $f
    | select(any($gate[0].code_changes[];
      .file == $f and (.attack | str) and (.result | str)) | not)
    | $f' "${LEDGER}")" ||
    die "could not read the gate attacks from ${GATE}"
  while IFS= read -r cfile; do
    [[ -n ${cfile} ]] || continue
    finding missing-attack "code change ${cfile} has no gate attack and result"
  done <<<"${unattacked}"
}

function main() {
  local class detail schema_bad=0 schema npairs nchanges
  schema="$(check_schema)" || die "could not check the schema of ${LEDGER}"
  schema+=$'\n'"$(check_gate_schema)" || die "could not check the schema of ${GATE}"
  while IFS=$'\t' read -r class detail; do
    [[ -n ${class} ]] || continue
    finding "${class}" "${detail}"
    [[ ${class} == schema ]] && schema_bad=1
  done <<<"${schema}"
  # Later checks read the ledger's shape; a schema finding stops here.
  if ((schema_bad == 0)); then
    check_artifacts
    check_completeness
    check_siblings
    check_verdicts
  fi
  if ((findings > 0)); then
    local tally='' c
    while IFS= read -r c; do
      tally+="${tally:+, }${c} ${class_count["${c}"]}"
    done < <(printf '%s\n' "${!class_count[@]}" | sort)
    printf '%s: %d finding(s) (%s)\n' "${PROG}" "${findings}" "${tally}" >&2
    exit 1
  fi
  npairs="$(jq '.pairs | length' "${LEDGER}")" || die "could not count pairs in ${LEDGER}"
  nchanges="$(jq '.code_changes | length' "${LEDGER}")" || die "could not count code_changes in ${LEDGER}"
  printf '%s: OK — %d pairs; %d hunks covered, %d reflow-only and %d generated skipped; %d code changes; %d changed and %d unchanged siblings\n' \
    "${PROG}" "${npairs}" "${HUNKS_COVERED}" "${HUNKS_REFLOW}" "${HUNKS_GENERATED}" "${nchanges}" \
    "${SIBLINGS_CHANGED}" "${SIBLINGS_UNCHANGED}"
}

main
