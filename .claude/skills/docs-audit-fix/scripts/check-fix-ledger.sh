#!/usr/bin/env bash
# .claude/skills/docs-audit-fix/scripts/check-fix-ledger.sh
#
# @description Pre-PR gate for a docs-audit fix pass. The writer records,
# per rewritten paragraph, the artifact the new sentence was written
# against and the sibling set it belongs to; a separate gate agent records
# a verdict and the hash of the paragraph it read. This script proves the
# record covers the branch's diff and still describes it:
#
#   completeness  every changed Markdown hunk outside generated blocks and
#                 pure reflow overlaps a recorded paragraph, and every other
#                 changed file is listed as a code change
#   artifacts     every recorded artifact range exists at the head revision;
#                 a command artifact is shape-checked and never run
#   anchors       every pair's lines lie inside one paragraph and hold the
#                 pair's anchor, a phrase the file holds once at head or
#                 a paragraph's whole text whose repeats all hash alike
#   siblings      an unchanged sibling names a range inside a tracked
#                 file and a reason; a changed one gains a substantively
#                 changed line in a covered hunk, a removed one borders a
#                 covered hunk that deletes text or sits in a file the
#                 diff deletes; outside in-scope Markdown any touching
#                 hunk clears it
#   sweep         every hit of a pair's sweep terms at the merge base falls,
#                 mapped to head, in the pair's paragraph or a sibling range,
#                 every term hits, and every finding has a pair with terms
#   verdicts      every pair is gated TRUE against its current text, and
#                 every code change carries the gate's adversarial attack
#                 against its current blob (else stale-attack)
#
# A paragraph is the blank-line-delimited block around the recorded lines,
# or, in a block that is a list, the item there (PARAGRAPH_AWK). Its hash
# covers that whole paragraph with whitespace collapsed, so a re-wrap
# leaves a verdict current, as does a shift in line numbers once the
# pair's recorded lines follow it, while any word change inside the
# paragraph makes it stale.
#
# Usage:
#   check-fix-ledger.sh [--base <rev>] [--head <rev>] <ledger.json> <gate.json>
#   check-fix-ledger.sh [--head <rev>] --hash <file> <start>-<end>
#   check-fix-ledger.sh [--base <rev>] [--head <rev>] --sweep [--] <term>...
#
# --sweep prints every hit of each term at the merge base, as
# "<file>:<start>-<end>: <first line>", with the matching a ledger pair's
# sweep terms get; a term that matches nothing is reported and exits 1.
#
# Exit codes:
#   0  the ledger covers the diff and every pair is currently gated TRUE
#      (--sweep: every term matched)
#   1  findings (printed to stderr, one line each); --sweep: a term
#      matched nothing
#   2  the check could not run: missing tool, bad arguments, unparsable
#      JSON or a key repeated inside one object, unresolvable revision,
#      uncommitted tracked changes, or a changed path git quotes

set -Eeuo pipefail
IFS=$'\n\t'
# Under a UTF-8 locale bash's [0-9] also matches non-ASCII digits (which
# the (( )) bound checks then fail on as an arithmetic error that `if`
# reads as false), and awk's [[:space:]] also matches non-ASCII spaces,
# so a paragraph's span, and with it the gate's hash, would depend
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
# The Markdown checked paragraph by paragraph, as git pathspecs: every
# .md file except the root CHANGELOG.md and anything under
# tests/fixtures/. This is the set's only definition. Completeness diffs
# through it, and the sibling checks read membership from a diff through
# it (IN_SCOPE_MD), so git does all the matching and no second spelling
# can drift from it.
readonly -a MD_ALL=('*.md')
readonly -a MD_SCOPE=("${MD_ALL[@]}" ':(exclude)CHANGELOG.md' ':(exclude)tests/fixtures')
# Where a pair's sweep terms are searched, as git pathspecs: every tracked
# file except the trees that carry deliberate violations (tests/fixtures/
# and any skill's seeded-defect fixtures), the root CHANGELOG.md (a
# historical record keeps its old wording) and the root flake.lock
# (data). This is not MD_SCOPE: that set is the Markdown checked paragraph
# by paragraph, while a claim's twin can sit in a workflow, a script or
# Nix comment, a harness or a recipe, so the sweep reads every kind of
# file. This is the sweep scope's only definition; --sweep and the ledger
# check both read it.
readonly -a SWEEP_SCOPE=('.' ':(exclude)CHANGELOG.md' ':(exclude)tests/fixtures'
  ':(exclude,glob).claude/skills/*/evals/seeded-defects/fixtures/**' ':(exclude)flake.lock')
# jq definitions every ledger and gate read shares, so a rule is written
# once: txt is a string holding a character that is neither white space
# nor an invisible format character (Unicode category Cf: a zero-width
# space, a byte-order mark, a soft hyphen), so text made only of those
# is blank. Some other characters print nothing too (a Hangul filler, a
# braille blank) and still count as text. iscmd marks a command artifact
# entry, which either of its keys makes one; arr reads anything but an
# array as an empty one. term is a usable sweep term or anchor: text with
# no newline, tab or CR, since terms are read one per line, and no NUL,
# which bash drops from jq's raw output. Oniguruma cannot match a NUL in
# a pattern, so it is found by code point.
readonly JQ_DEFS='
  def txt: type == "string" and test("[^\\s\\p{Cf}]");
  def term: txt and (test("[\\n\\t\\r]") | not) and (explode | any(. == 0) | not);
  def iscmd: has("command") or has("observed");
  def arr: if type == "array" then . else [] end;
'
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

for tool in git jq awk sed grep sort sha256sum tr cut realpath; do
  command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
done

function collapse() {
  tr --squeeze-repeats '[:space:]' ' ' | sed --expression 's/^ //' --expression 's/ $//'
}

# @description True when $1 is exactly a "<start>-<end>" range with each
# number 1-6 digits. check_schema's rng shape-checks pair and artifact
# ranges, but not sibling ranges, so this is what guards a sibling range
# before it feeds an arithmetic ((...)) expression; a bash arithmetic
# error there is read by `if` as false rather than raised, silently
# skipping the bound check it guards. Its uses on pair and artifact
# ranges (the pair, artifact and verdict re-checks) are defence in depth:
# a bad one is a schema finding, which stops those checks from running.
function valid_range() {
  [[ $1 =~ ^[1-9][0-9]{0,5}-[1-9][0-9]{0,5}$ ]]
}

# The paragraph model every paragraph check shares, as an awk prefix: it
# keeps each line of stdin in ln[], and mark_paragraphs() (called from END)
# sets blank[i] for a line that is empty or white space only, and cut[i]
# for a line that starts a paragraph although the line above it is not
# blank. A paragraph runs from a line after a blank line (or the first
# line), or from a cut line, to the line before the next blank or cut line.
#
# A cut line is a list item: in a block whose first line is a list marker
# at an indent of N spaces, every later line holding a marker at exactly
# N spaces starts a paragraph of its own, running on through its
# continuation lines and any nested list. A marker is -, * or +, or one to
# nine digits then . or ), followed by a space, a tab or the end of the
# line. A block whose first line is not a marker (a fenced block, a
# paragraph, a table) is never split, and a tab-indented marker is not
# read as one, so either stays one larger paragraph. mdformat separates
# every other block with a blank line, so on a formatted file this is
# CommonMark'"'"'s list item.
# shellcheck disable=SC2016 # an awk program: its $0 is awk's, not the shell's
readonly PARAGRAPH_AWK='
  { ln[NR] = $0 }
  function marker_indent(l,   pad) {
    if (l !~ /^ *([-*+]|[0-9][0-9]?[0-9]?[0-9]?[0-9]?[0-9]?[0-9]?[0-9]?[0-9]?[.)])([ \t]|$)/) return -1
    pad = l
    sub(/[^ ].*$/, "", pad)
    return length(pad)
  }
  function mark_paragraphs(   i, ind) {
    ind = -1
    for (i = 1; i <= NR; i++) {
      blank[i] = (ln[i] ~ /^[[:space:]]*$/)
      cut[i] = 0
      if (blank[i]) continue
      if (i == 1 || blank[i - 1]) ind = marker_indent(ln[i])
      else if (ind >= 0 && marker_indent(ln[i]) == ind) cut[i] = 1
    }
  }'

# @description Print "<a> <b>": the paragraph(s) that contain lines
# $1..$2 of stdin.
function paragraph_span() {
  awk -v s="$1" -v e="$2" "${PARAGRAPH_AWK}"'
    END {
      mark_paragraphs()
      a = s; while (a > 1 && !blank[a - 1] && !cut[a]) a--
      b = e; while (b < NR && !blank[b + 1] && !cut[b + 1]) b++
      print a, b
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

# @description True when $2 names an object at revision $1.
function is_tracked() {
  git cat-file -e "$1:$2" 2>/dev/null
}

# @description True when $2 names a file (a blob, not a tree or a
# gitlink) at revision $1.
function is_file() {
  is_tracked "$1" "$2" && [[ "$(git cat-file -t "$1:$2")" == blob ]]
}

# @description The number of lines file $2 holds at revision $1.
function line_count() {
  git show "$1:$2" | awk 'END { print NR }'
}

function paragraph_hash() {
  local -r rev="$1" file="$2" start="$3" end="$4"
  local span a b
  span="$(git show "${rev}:${file}" | paragraph_span "${start}" "${end}")"
  a="${span% *}"
  b="${span#* }"
  git show "${rev}:${file}" | sed --quiet "${a},${b}p" | collapse |
    sha256sum | cut --delimiter=' ' --fields=1
}

# @description Print "<start>\t<end>\t<text of line start>" for each place stdin holds the
# term in ${SWEEP_TERM}, outside the generated ranges in ${SWEEP_GEN}
# ("start end" per line, markers inclusive). Matching is a fixed string,
# case-sensitive, within one blank-line block (list items are not split
# here, since the sweep reads every kind of file): each line loses its
# leading white space and a leading run of "#" followed by white space (a
# comment marker), a line left empty ends the block, and white space is
# collapsed in the block and the term alike, so a term wrapped across
# lines or comment lines still matches, reported with the lines it spans.
# The term comes through the environment, since awk -v would read its
# backslashes as escapes.
# shellcheck disable=SC2016 # an awk program: its $0 is awk's, not the shell's
readonly SWEEP_AWK='
  function flush(   from, p, pos, last, i, s, e, g, a) {
    from = 1
    while (n > 0 && (p = index(substr(blk, from), t)) > 0) {
      pos = from + p - 1
      last = pos + length(t) - 1
      for (i = 1; i <= n; i++) { if (off[i] <= pos) s = ln[i]; if (off[i] <= last) e = ln[i] }
      inside = 0
      for (g = 1; g <= ng; g++) if (s >= ga[g] && e <= gb[g]) inside = 1
      if (!inside) print s "\t" e "\t" raw[s]
      from = pos + length(t)
    }
    n = 0; blk = ""
  }
  BEGIN {
    t = ENVIRON["SWEEP_TERM"]
    gsub(/[[:space:]]+/, " ", t); sub(/^ /, "", t); sub(/ $/, "", t)
    ng = split(ENVIRON["SWEEP_GEN"], rows, "\n"); k = 0
    for (g = 1; g <= ng; g++) if (split(rows[g], f, " ") >= 2) { k++; ga[k] = f[1] + 0; gb[k] = f[2] + 0 }
    ng = k
  }
  {
    line = $0
    raw[NR] = $0
    sub(/^[[:space:]]+/, "", line)
    if (line ~ /^#+([[:space:]]|$)/) sub(/^#+[[:space:]]*/, "", line)
    gsub(/[[:space:]]+/, " ", line); sub(/ $/, "", line)
    if (line == "") { flush(); next }
    n++; ln[n] = NR
    if (blk == "") { off[n] = 1; blk = line } else { off[n] = length(blk) + 2; blk = blk " " line }
  }
  END { flush() }'

# @description True when $1 is a usable sweep term, by JQ_DEFS' term.
function is_term() {
  jq --null-input --exit-status --arg t "$1" "${JQ_DEFS}"'$t | term' >/dev/null 2>&1
}

# @description Hits of sweep term $1 at the merge base ${MB} across
# SWEEP_SCOPE, as "<file>\t<start>\t<end>\t<first line>" lines, from the
# repository root. git grep narrows the files to those holding every word
# of the term somewhere, then SWEEP_AWK finds the term itself. A file
# holding a NUL byte is skipped as binary; git grep's own -I is not used,
# since it also skips a text file a -diff or binary attribute marks, and a
# caller's attributes must not hide a twin. --no-color keeps color.grep
# out of the name list, --no-recurse-submodules keeps submodule.recurse
# from reaching files the merge base does not hold, -z keeps names
# unquoted, and -F makes grep.patternType irrelevant. Names come back
# NUL-separated; one holding a newline or tab cannot be carried through
# the line- and tab-separated hit list, so it stops the run.
function sweep_hits() {
  local -r term="$1"
  local -a words=() args=()
  local w names rc=0 f spans
  IFS=$' \t\n\v\f\r' read -r -a words <<<"${term}"
  for w in "${words[@]}"; do args+=(-e "${w}"); done
  names="$(
    git grep --no-color --no-recurse-submodules --text -l -z -F --all-match \
      "${args[@]}" "${MB}" -- "${SWEEP_SCOPE[@]}" |
      tr '\0\n\t' '\n\001\002'
    exit "${PIPESTATUS[0]}"
  )" || rc=$?
  ((rc <= 1)) || die "could not search the merge base for the term ${term}"
  local size text row
  while IFS= read -r f; do
    [[ -n ${f} ]] || continue
    f="${f#"${MB}":}"
    # tr carried a newline as 0x01 and a tab as 0x02, so a name holding
    # any of the four cannot be told apart; each shows as "?".
    if [[ ${f} == *[$'\001\002']* ]]; then
      die "cannot sweep ${f//[$'\001\002']/?}: its name holds a tab, newline, 0x01 or 0x02 byte (shown as ?); rename it"
    fi
    size="$(git cat-file -s "${MB}:${f}")" || die "could not read ${f} at the merge base"
    text="$(git cat-file blob "${MB}:${f}" | tr -d '\000' | wc -c)" ||
      die "could not read ${f} at the merge base"
    ((size == text)) || continue
    spans="$(git show "${MB}:${f}" | generated_ranges)" ||
      die "could not read ${f} at the merge base"
    git show "${MB}:${f}" | SWEEP_TERM="${term}" SWEEP_GEN="${spans}" awk "${SWEEP_AWK}" |
      while IFS= read -r row; do printf '%s\t%s\n' "${f}" "${row}"; done ||
      die "could not search ${f} at the merge base"
  done <<<"${names}"
}

# @description Print the merge base of BASE and HEAD_REV, or stop.
function merge_base() {
  git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null ||
    die "base revision does not resolve: ${BASE}"
  git merge-base "${BASE}" "${HEAD_REV}" || die "no merge base for ${BASE} and ${HEAD_REV}"
}

BASE='main'
HEAD_REV='HEAD'
hash_mode=0
sweep_mode=0
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
  --sweep)
    sweep_mode=1
    shift
    ;;
  --)
    shift
    positional+=("$@")
    break
    ;;
  -*) die "unknown option: $1" ;;
  *)
    positional+=("$1")
    shift
    ;;
  esac
done
readonly BASE HEAD_REV
((hash_mode && sweep_mode)) && die '--sweep and --hash cannot be combined'

git rev-parse --verify --quiet "${HEAD_REV}^{commit}" >/dev/null ||
  die "head revision does not resolve: ${HEAD_REV}"

if ((hash_mode)); then
  ((${#positional[@]} == 2)) || die 'usage: --hash <file> <start>-<end>'
  [[ ${positional[1]} =~ ^([1-9][0-9]{0,5})-([1-9][0-9]{0,5})$ ]] || die "bad range: ${positional[1]}"
  hash_start="${BASH_REMATCH[1]}"
  hash_end="${BASH_REMATCH[2]}"
  ((hash_start >= 1 && hash_start <= hash_end)) ||
    die "bad range: ${positional[1]} (start must be >= 1 and <= end)"
  is_tracked "${HEAD_REV}" "${positional[0]}" ||
    die "not tracked at ${HEAD_REV}: ${positional[0]}"
  is_file "${HEAD_REV}" "${positional[0]}" ||
    die "not a file at ${HEAD_REV}: ${positional[0]}"
  hash_n="$(line_count "${HEAD_REV}" "${positional[0]}")"
  ((hash_end <= hash_n)) ||
    die "bad range: ${positional[1]} (end must be <= ${hash_n} lines)"
  paragraph_hash "${HEAD_REV}" "${positional[0]}" "${hash_start}" "${hash_end}"
  exit 0
fi

if ((sweep_mode)); then
  ((${#positional[@]} > 0)) || die 'usage: --sweep <term>...'
  for term in "${positional[@]}"; do
    is_term "${term}" ||
      die "bad sweep term: $(jq --null-input --raw-output --arg t "${term}" '$t | tojson') (needs text, and no newline, tab or CR)"
  done
  cd -- "$(git rev-parse --show-toplevel)" || die 'not inside a git work tree'
  MB="$(merge_base)" || exit 2
  readonly MB
  sweep_status=0
  declare -A shown=()
  for term in "${positional[@]}"; do
    hits="$(sweep_hits "${term}")" || exit 2
    if [[ -z ${hits} ]]; then
      printf '%s: term "%s" matches nothing in the sweep scope at the merge base\n' "${PROG}" "${term}" >&2
      sweep_status=1
      continue
    fi
    # Split by expansion, not read: tab is IFS white space, so read would
    # trim a first line's leading and trailing tabs.
    while IFS= read -r row; do
      file="${row%%$'\t'*}"
      row="${row#*$'\t'}"
      start="${row%%$'\t'*}"
      row="${row#*$'\t'}"
      end="${row%%$'\t'*}"
      first="${row#*$'\t'}"
      [[ -z ${shown["${file}:${start}-${end}"]:-} ]] || continue
      shown["${file}:${start}-${end}"]=1
      printf '%s:%s-%s: %s\n' "${file}" "${start}" "${end}" "${first}"
    done <<<"${hits}"
  done
  exit "${sweep_status}"
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
  # A key repeated inside one object resolves to its last value, so an
  # earlier FALSE verdict (or siblings list) would be shadowed by a later
  # one. The parsed value cannot show it; the token stream can. A value
  # at path P is finished once its leaf is emitted, and a container once
  # the event closing its last child is, so a leaf under a finished path
  # is a second value for that key.
  repeated="$(jq --stream --null-input --raw-output '
    reduce inputs as $e ({done: {}, hit: null};
      . as $s
      | if $s.hit != null then $s
        else ($e[0]) as $p
        | if ($e | length) == 2 then
            ([range(1; ($p | length) + 1) as $n | $p[:$n]
              | select($s.done[tojson])] | first) as $hit
            | if $hit != null then $s | .hit = $hit
              else $s | .done[$p | tojson] = true end
          else $s | .done[$p[:-1] | tojson] = true end
        end)
    | .hit // empty
    | map(if type == "number" then "[\(.)]"
        elif (test("\n") | not) and test("^[A-Za-z_][A-Za-z0-9_]*$") then ".\(.)"
        else "[\(tojson)]" end) | join("")' \
    "${json_file}")" || die "could not read the keys of ${json_file}"
  [[ -z ${repeated} ]] || die "${json_file} repeats key ${repeated}"
done
MB="$(merge_base)" || exit 2
# The merge base every diff and reflow comparison reads its old side from.
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
  jq --raw-output "${JQ_DEFS}"'
    def str: type == "string" and length > 0;
    # test() with $ matches before a trailing newline (Oniguruma), so
    # "1-999999\n" would otherwise pass; the explicit no-newline check
    # closes that regardless of anchor semantics.
    def rng: str and (test("\n") | not) and test("^[1-9][0-9]{0,5}-[1-9][0-9]{0,5}$");
    def ctl: type == "string" and test("[\n\t\r]");
    def rooted: type == "string" and (startswith("./") or startswith("/"));
    def rootmsg: "starts with ./ or /; name it from the repository root";
    def shown: gsub("\n"; "<LF>") | gsub("\t"; "<TAB>") | gsub("\r"; "<CR>")
      | [explode[] | if . == 0 then "<NUL>" else [.] | implode end] | join("");
    def rendered: if type == "string" then "\"\(shown)\"" else tojson end;
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
      # An artifact entry is a tracked range ({file, lines}) or, for a
      # fact that lives outside the tree, the command that shows it and
      # what it printed ({command, observed}); either key alone makes an
      # entry a command entry. Only the shape of a command entry is
      # checked: the checker never runs it.
      ([.artifact | arr | to_entries[] | select(.value | type == "object")
        | select((.value | iscmd | not)
            and (((.value.file | str) and (.value.lines | rng)) | not))
        | .key]) as $badfile |
      (if (.artifact | type) == "array" and (.artifact | length) > 0 then
        ($badfile[] | ["schema", "pair \($id) artifact[\(.)] needs a file and a <start>-<end> lines"])
      else ["schema", "pair \($id) needs a non-empty artifact list"] end),
      ((.artifact | arr) | to_entries[] | select(.value | type == "object")
        | select(.value | iscmd) | .key as $k | .value
        | if has("file") or has("lines") then
            ["schema", "pair \($id) artifact[\($k)] holds both command and file keys (\(keys | join(", "))); give each its own entry"]
          else
            (if .command | txt then empty
            else ["schema", "pair \($id) artifact[\($k)] needs a non-blank command string, got \(.command | tojson)"] end),
            (if .observed | txt then empty
            else ["schema", "pair \($id) artifact[\($k)] needs a non-blank observed string, got \(.observed | tojson)"] end)
          end),
      (.siblings | nonobj("pair \($id) siblings")),
      (if (.siblings | type) == "array" and all(.siblings[] | objects; .file | str) then empty
      else ["schema", "pair \($id) needs a siblings list whose members name a file"] end),
      (if .fix_shape == "drop" or .fix_shape == "scope" or .fix_shape == "correct" then empty
      else ["enum", "pair \($id) fix_shape \(.fix_shape | tojson) is not drop, scope or correct"] end),
      # finding groups pairs for missing-sweep, so a missing, string or
      # fractional value would merge or split the groups.
      (if (.finding | type) == "number" and .finding >= 1 and (.finding | floor) == .finding then empty
      else ["schema", "pair \($id) needs a finding number (a whole number of 1 or more), got \(.finding | rendered)"] end),
      # sweep is optional; when present it is a non-empty list of terms.
      (if has("sweep") | not then empty
      elif (.sweep | type) != "array" then
        ["schema", "pair \($id) sweep must be a list of terms, got \(.sweep | rendered)"]
      elif (.sweep | length) == 0 then
        ["schema", "pair \($id) sweep is an empty list; omit the field or name a term"]
      else
        (.sweep | to_entries[] | select(.value | term | not)
          | ["schema", "pair \($id) sweep[\(.key)] needs a non-blank term with no newline, tab, CR or NUL, got \(.value | rendered)"])
      end),
      # anchor is required: a phrase inside the lines of the pair, which ties
      # them to the text the writer paired (check_anchors).
      (if .anchor | term then empty
      else ["schema", "pair \($id) needs an anchor (a non-blank phrase inside its lines, with no newline, tab, CR or NUL), got \(.anchor | rendered)"] end),
      ((.siblings | arr)[] | objects | select(.status != "changed" and .status != "unchanged" and .status != "removed")
        | ["enum", "pair \($id) sibling \(.file) status \(.status | tojson) is not changed, unchanged or removed"])),
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
        | ["schema", "pair \($id) sibling file \"\(.file | shown)\" holds a newline, tab or CR"])),
    # Git prints paths from the repository root with no "./" or "/" in
    # front, so a file named that way matches no hunk or listed change: the
    # hunk a pair covers would read as uncovered with nothing naming the pair.
    ((.code_changes | arr)[] | objects | select(.file | rooted)
      | ["schema", "code_changes file \"\(.file | shown)\" \(rootmsg)"]),
    ((.pairs | arr)[] | objects | (.id // "?") as $id |
      (select(.file | rooted)
        | ["schema", "pair \($id) file \"\(.file | shown)\" \(rootmsg)"]),
      ((.artifact | arr)[] | objects | select(.file | rooted)
        | ["schema", "pair \($id) artifact file \"\(.file | shown)\" \(rootmsg)"]),
      ((.siblings | arr)[] | objects | select(.file | rooted)
        | ["schema", "pair \($id) sibling file \"\(.file | shown)\" \(rootmsg)"]))
    | @tsv' "${LEDGER}"
}

# @description Gate schema findings, in check_schema's format. The gate's
# pairs and code_changes lists must hold objects, so the verdict checks
# that read them never index a string or number. Each verdict id must be
# unique (with two, which one counts would depend on order) and must name
# a ledger pair (a verdict for no pair gates nothing, and usually means
# the gate read a different ledger). Each code change entry must carry
# the blob id it attacked, or "deleted" for a file absent at head, so an
# attack can be tied to the code it ran against.
function check_gate_schema() {
  jq --raw-output --slurpfile ledger "${LEDGER}" "${JQ_DEFS}"'
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
      | ["enum", "verdict for pair \(.id) \(.verdict | tojson) is not TRUE, FALSE or OVERREACHES"]),
    ((.code_changes | arr)[] | objects
      | select((.blob | type == "string" and (test("\n") | not)
          and test("^([0-9a-f]{40}|[0-9a-f]{64}|deleted)$")) | not)
      | ["schema", "gate code change \(.file) needs a blob (the head blob id it attacked, or \"deleted\"), got \(.blob | tojson)"])
    | @tsv' "${GATE}"
}

# @description Each file artifact must be tracked at head with its range
# inside the file. A command artifact names no file and is skipped.
function check_artifacts() {
  local id file lines start end n records
  records="$(jq --raw-output "${JQ_DEFS}"'.pairs[] | .id as $id | .artifact[] | select(iscmd | not) | [$id, .file, .lines] | @tsv' "${LEDGER}")" ||
    die "could not read the artifact list from ${LEDGER}"
  while IFS=$'\t' read -r id file lines; do
    [[ -n ${id} ]] || continue
    if ! is_tracked "${HEAD_REV}" "${file}"; then
      finding artifact "pair ${id} ${file} is not tracked at the head revision"
      continue
    fi
    if ! is_file "${HEAD_REV}" "${file}"; then
      finding artifact "pair ${id} ${file} is not a file at the head revision"
      continue
    fi
    # Defence in depth: check_schema's rng already rejects a bad range.
    if ! valid_range "${lines}"; then
      finding schema "pair ${id} artifact ${file}:${lines} is not a valid <start>-<end> range"
      continue
    fi
    start="${lines%-*}"
    end="${lines#*-}"
    if ((start > end)); then
      finding artifact "pair ${id} ${file}:${lines} is reversed (start ${start} > end ${end})"
      continue
    fi
    n="$(line_count "${HEAD_REV}" "${file}")"
    if ((end > n)); then
      finding artifact "pair ${id} ${file}:${lines} runs past end of file (${n} lines)"
    fi
  done <<<"${records}"
}

# @description The text of the paragraph around lines $3..$4 of file $2
# at revision $1 as SWEEP_AWK reads it: each line loses its leading white
# space and a leading "#" run, white space is collapsed, and the lines are
# joined. A line the stripping leaves empty is skipped, where SWEEP_AWK
# ends its paragraph instead, so a paragraph holding one is never the
# whole text of a match.
function paragraph_text() {
  local -r rev="$1" file="$2" start="$3" end="$4"
  local span
  span="$(git show "${rev}:${file}" | paragraph_span "${start}" "${end}")"
  # shellcheck disable=SC2016 # an awk program: its $0 is awk's, not the shell's
  git show "${rev}:${file}" | sed --quiet "${span% *},${span#* }p" | awk '
    { sub(/^[[:space:]]+/, "")
      if ($0 ~ /^#+([[:space:]]|$)/) sub(/^#+[[:space:]]*/, "")
      gsub(/[[:space:]]+/, " "); sub(/ $/, "")
      if ($0 != "") out = out (out == "" ? "" : " ") $0 }
    END { print out }'
}

# @description Each pair's lines must lie inside one paragraph and hold
# its anchor, the file's only match for it at head. The gate hashes and
# judges the text at lines, so a range a later commit moved would put the
# verdict on another paragraph; the anchor is the writer's record of which
# text was paired. The match is SWEEP_AWK's, with no generated range left
# out. Without the one-paragraph rule a stale range that takes in a blank
# line, or the end of one list item, and the anchor's line would pass,
# with its hash spanning both neighbouring paragraphs. A pair whose file
# or range check_completeness
# rejects is skipped here.
#
# Where the file holds the anchor more than once, only the matches that
# are their paragraph's whole text count: a heading, whose text is its
# only text, a list item, or a line fixed to repeat another. They must all hash alike,
# so that a range on any of them carries the same verdict, and one must
# lie inside lines. A heading and a plain line with its words are both
# whole matches that hash apart, so they stay a repeat.
function check_anchors() {
  local k id file lines anchor s e n hits hs he where records anchors count inside rc
  local flat wholes whole_in hash first_hash hashes_differ
  local -a aid=() afile=() alines=()
  records="$(jq --raw-output '.pairs | to_entries[] | [(.key | tostring), .value.id, .value.file, .value.lines] | @tsv' "${LEDGER}")" ||
    die "could not read the pair list from ${LEDGER}"
  while IFS=$'\t' read -r k id file lines; do
    [[ -n ${k} ]] || continue
    aid[k]="${id}"
    afile[k]="${file}"
    alines[k]="${lines}"
  done <<<"${records}"
  # Read raw, one per line (check_schema confined an anchor to no
  # newline, tab, CR or NUL), so a backslash is not doubled as @tsv would.
  anchors="$(jq --raw-output '.pairs | to_entries[] | [(.key | tostring), .value.anchor] | join("\t")' "${LEDGER}")" ||
    die "could not read the anchors from ${LEDGER}"
  while IFS=$'\t' read -r k anchor; do
    [[ -n ${k} ]] || continue
    id="${aid[k]}"
    file="${afile[k]}"
    lines="${alines[k]}"
    is_file "${HEAD_REV}" "${file}" || continue
    valid_range "${lines}" || continue
    s="${lines%-*}"
    e="${lines#*-}"
    n="$(line_count "${HEAD_REV}" "${file}")"
    ((s <= e && e <= n)) || continue
    rc=0
    git show "${HEAD_REV}:${file}" | one_paragraph "${s}" "${e}" || rc=$?
    if ((rc == 1)); then
      finding schema "pair ${id} ${file}:${lines} holds a blank line; a pair's lines lie inside one paragraph"
      continue
    elif ((rc != 0)); then
      finding schema "pair ${id} ${file}:${lines} spans more than one list item; a pair's lines lie inside one paragraph"
      continue
    fi
    # One line holding the anchor twice is listed once.
    hits="$(git show "${HEAD_REV}:${file}" | SWEEP_TERM="${anchor}" SWEEP_GEN='' awk "${SWEEP_AWK}" | cut --fields=1,2 | uniq)" ||
      die "could not search ${file} for the anchor of pair ${id}"
    if [[ -z ${hits} ]]; then
      finding anchor "pair ${id} anchor \"${anchor}\" matches nothing in ${file} at the head revision"
      continue
    fi
    count=0
    inside=0
    where=''
    while IFS=$'\t' read -r hs he; do
      count=$((count + 1))
      where+="${hs}-${he} "
      ((hs >= s && he <= e)) && inside=1
    done <<<"${hits}"
    where="${where% }"
    if ((count == 1)); then
      ((inside)) ||
        finding anchor "pair ${id} anchor \"${anchor}\" is at ${file}:${where}, outside its lines ${lines}; point lines at it or anchor on text inside them"
      continue
    fi
    flat="$(collapse <<<"${anchor}")"
    wholes=''
    whole_in=0
    first_hash=''
    hashes_differ=0
    while IFS=$'\t' read -r hs he; do
      [[ "$(paragraph_text "${HEAD_REV}" "${file}" "${hs}" "${he}")" == "${flat}" ]] || continue
      wholes+="${hs}-${he} "
      ((hs >= s && he <= e)) && whole_in=1
      hash="$(paragraph_hash "${HEAD_REV}" "${file}" "${hs}" "${he}")"
      if [[ -z ${first_hash} ]]; then
        first_hash="${hash}"
      elif [[ ${hash} != "${first_hash}" ]]; then
        hashes_differ=1
      fi
    done <<<"${hits}"
    wholes="${wholes% }"
    if [[ -z ${wholes} ]] || ((hashes_differ)); then
      finding anchor "pair ${id} anchor \"${anchor}\" matches ${file} more than once (${where}); name a phrase the file holds once"
    elif ((whole_in)); then
      :
    elif [[ ${wholes} == *' '* ]]; then
      finding anchor "pair ${id} anchor \"${anchor}\" is at ${file} (${wholes}), outside its lines ${lines}; point lines at it or anchor on text inside them"
    else
      finding anchor "pair ${id} anchor \"${anchor}\" is at ${file}:${wholes}, outside its lines ${lines}; point lines at it or anchor on text inside them"
    fi
  done <<<"${anchors}"
}

HUNKS_COVERED=0
HUNKS_REFLOW=0
HUNKS_GENERATED=0
SIBLINGS_CHANGED=0
SIBLINGS_UNCHANGED=0
SIBLINGS_REMOVED=0
ALL_HUNKS=''
# Markdown hunks check_completeness reported uncovered, in list_hunks'
# "hunks" format and, for the removed-sibling reach, as "file\tns\tol\tnl",
# so a sibling they touch is named as sitting in a hunk that waits on a
# pair.
UNCOVERED_HUNKS=''
UNCOVERED_REMOVALS=''
# Added Markdown lines whose text changed, as "file\tos\tns\tline" for
# every hunk (list_hunks lines), and as "file\tline" for only the hunks
# check_completeness counted as covered: reflow-only and generated-block
# hunks, and padding-only lines inside a covered hunk, are left out.
MD_CHANGED_LINES=''
SUBSTANTIVE_LINES=''
# Markdown hunks that delete text, as "file\tos\tns" for every hunk
# (list_hunks deletions), and as "file\tns\tol\tnl" for only the covered
# ones.
MD_DELETING_HUNKS=''
DELETING_HUNKS=''
# Files the diff changes inside MD_SCOPE, as keys; set by
# check_completeness for check_siblings. A sibling in an in-scope file the
# diff leaves alone reads as out of scope here, which decides nothing:
# neither the in-scope test nor the any-hunk test finds a hunk there.
declare -A IN_SCOPE_MD=()

# @description Names of the files changed between the merge base and
# head, one per line; "$@" is extra `git diff` arguments (a
# --diff-filter, then pathspecs after --).
function changed_names() {
  git -c core.quotePath=false diff --no-ext-diff --no-textconv \
    --diff-algorithm=myers --no-indent-heuristic --ignore-submodules=none \
    --src-prefix=a/ --dst-prefix=b/ --name-only --no-renames "${MB}" "${HEAD_REV}" "$@"
}

# @description Count one covered hunk ($1..$5, as list_hunks prints it)
# and record its changed lines in SUBSTANTIVE_LINES and, when it deletes
# text, the hunk in DELETING_HUNKS.
function count_covered() {
  local lf los lns line
  HUNKS_COVERED=$((HUNKS_COVERED + 1))
  while IFS=$'\t' read -r lf los lns line; do
    [[ ${lf} == "$1" && ${los} == "$2" && ${lns} == "$4" ]] || continue
    SUBSTANTIVE_LINES+="${lf}"$'\t'"${line}"$'\n'
  done <<<"${MD_CHANGED_LINES}"
  while IFS=$'\t' read -r lf los lns; do
    [[ ${lf} == "$1" && ${los} == "$2" && ${lns} == "$4" ]] || continue
    DELETING_HUNKS+="$1"$'\t'"$4"$'\t'"$3"$'\t'"$5"$'\n'
  done <<<"${MD_DELETING_HUNKS}"
}

# @description Unified-zero hunks between the merge base and head. Mode $1
# "hunks" prints one "file\tos\tol\tns\tnl" row per hunk; mode "lines"
# prints "file\tos\tns\tline" for each added line whose
# whitespace-collapsed text matches no collapsed removed line of the same
# hunk, i.e. each line whose words changed rather than only its padding
# (a re-aligned table row, a trailing space); mode "deletions" prints
# "file\tos\tns" for each hunk holding a removed line whose collapsed
# text matches no collapsed added line of that hunk. The rest of "$@" is
# pathspecs. Paths come from the "+++ b/" header, read from
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
# setting; --diff-algorithm=myers and --no-indent-heuristic pin where
# hunk boundaries fall, which a configured diff.algorithm or
# diff.indentHeuristic would otherwise move, so the same branch could pass
# for one caller and fail for another; --ignore-submodules=none keeps a
# diff.ignoreSubmodules setting from hiding a changed gitlink, and
# --submodule=short keeps diff.submodule=log from replacing its
# "Subproject commit" hunk with a summary line that yields no rows.
function list_hunks() {
  local -r mode="$1"
  shift
  git -c core.quotePath=false diff --no-ext-diff \
    --no-textconv --text --src-prefix=a/ --dst-prefix=b/ --no-color \
    --diff-algorithm=myers --no-indent-heuristic --ignore-submodules=none \
    --submodule=short --no-renames --unified=0 --inter-hunk-context=0 \
    "${MB}" "${HEAD_REV}" -- "$@" |
    awk -v prog="${PROG}" -v mode="${mode}" '
      function bad(why) {
        printf "%s: unparsable diff line %d (%s): %s\n", prog, NR, why, $0 > "/dev/stderr"
        failed = 1
        exit 2
      }
      function squash(t) {
        gsub(/[[:space:]]+/, " ", t); sub(/^ /, "", t); sub(/ $/, "", t)
        return t
      }
      ro > 0 || rn > 0 {
        c = substr($0, 1, 1)
        if (c == "\\") next
        if (c == "-") {
          if (ro == 0) bad("removed line past the hunk count")
          ro--; t = squash(substr($0, 2)); removed[t] = 1; removed_text[nr] = t; nr++
        } else if (c == "+") {
          if (rn == 0) bad("added line past the hunk count")
          rn--; t = squash(substr($0, 2)); added[t] = 1
          added_at[na] = nn; added_text[na] = t; na++; nn++
        } else if (c == " ") {
          if (ro == 0 || rn == 0) bad("context line past the hunk count")
          ro--; rn--; nn++
        } else {
          bad("unknown hunk body prefix")
        }
        if (ro == 0 && rn == 0 && mode == "lines" && f != "") {
          for (i = 0; i < na; i++) {
            if (!(added_text[i] in removed)) print f "\t" o[1] "\t" n[1] "\t" added_at[i]
          }
        }
        if (ro == 0 && rn == 0 && mode == "deletions" && f != "") {
          for (i = 0; i < nr; i++) {
            if (!(removed_text[i] in added)) { print f "\t" o[1] "\t" n[1]; break }
          }
        }
        next
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
        nn = n[1] + 0; na = 0; nr = 0; split("", removed); split("", added)
        if (mode == "hunks" && f != "") print f "\t" o[1] "\t" ol "\t" n[1] "\t" nl
      }
      END { if (!failed && (ro > 0 || rn > 0)) bad("diff ends inside a hunk") }'
}

# @description True when every line $3..$4 of $1:$2 is empty or
# whitespace-only.
function all_blank() {
  local -r rev="$1" file="$2" start="$3" end="$4"
  ! git show "${rev}:${file}" | awk -v s="${start}" -v e="${end}" '
    NR >= s && NR <= e && $0 !~ /^[[:space:]]*$/ { bad = 1 }
    END { exit bad ? 0 : 1 }'
}

# @description True when the old paragraphs around the hunk and the new
# paragraphs around it hold the same words in the same order — a re-wrap.
# False (rather than a garbage compare) when either side's span falls
# outside its file, which a hunk misattributed to the wrong file can
# produce. A pure insertion or deletion (ol==0 or nl==0) is a re-wrap only
# when every added/removed line is blank; a blank-line anchor otherwise
# lets paragraph_span expand across it and join the paragraphs on both
# sides, so a duplicated paragraph being inserted or deleted (or a
# duplicate wrapped differently) can collapse to the same text as its
# neighbour and read as a re-wrap even though real content was added or
# removed. A pure insertion or deletion of blank lines alone changes no
# words, whichever list items or paragraphs they sit between, so it is a
# re-wrap with no span to compare.
function is_reflow() {
  local -r file="$1" os="$2" ol="$3" ns="$4" nl="$5"
  is_tracked "${MB}" "${file}" || return 1
  local mb_n hd_n
  mb_n="$(line_count "${MB}" "${file}")"
  hd_n="$(line_count "${HEAD_REV}" "${file}")"
  local oe=$((os + (ol > 0 ? ol - 1 : 0))) ne=$((ns + (nl > 0 ? nl - 1 : 0)))
  ((os >= 1 && oe <= mb_n && ns >= 1 && ne <= hd_n)) || return 1
  if ((ol == 0)) && ! all_blank "${HEAD_REV}" "${file}" "${ns}" "${ne}"; then
    return 1
  fi
  if ((nl == 0)) && ! all_blank "${MB}" "${file}" "${os}" "${oe}"; then
    return 1
  fi
  # Only blank lines went in or out, so no word changed.
  ((ol > 0 && nl > 0)) || return 0
  local ospan nspan old new
  ospan="$(git show "${MB}:${file}" | paragraph_span "${os}" "${oe}")"
  nspan="$(git show "${HEAD_REV}:${file}" | paragraph_span "${ns}" "${ne}")"
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
  is_tracked "${MB}" "${file}" || return 1
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

# @description Maximal runs of the line range $2..$3 of file $1 at HEAD
# that lie inside one paragraph, split at any blank line or paragraph
# start inside that range, as "start end" per run. A run is not extended
# past $2 or $3 into unchanged context — e.g. a fixed marker line the hunk
# merely abuts — only the hunk's own range is split.
function new_side_paragraphs() {
  local -r file="$1" ns="$2" ne="$3"
  git show "${HEAD_REV}:${file}" | awk -v ns="${ns}" -v ne="${ne}" "${PARAGRAPH_AWK}"'
    END {
      mark_paragraphs()
      a = 0
      for (i = ns; i <= ne + 1; i++) {
        isblank = (i > ne) ? 1 : blank[i]
        if (!isblank) {
          if (a != 0 && cut[i]) {
            print a, i - 1
            a = 0
          }
          if (a == 0) a = i
        } else if (a != 0) {
          print a, i - 1
          a = 0
        }
      }
    }'
}

# @description True when a pair span of file $1 in the list $4 (as
# "file\ta\tb" lines) overlaps lines $2..$3.
function span_overlaps() {
  local -r file="$1" s="$2" e="$3" spans="$4"
  local pf pa pb
  while IFS=$'\t' read -r pf pa pb; do
    [[ ${pf} == "${file}" ]] || continue
    ((s <= pb && e >= pa)) && return 0
  done <<<"${spans}"
  return 1
}

function check_completeness() {
  local file os ol ns nl hs he ne block_a block_b covered block_count
  local md_hunks
  md_hunks="$(list_hunks hunks "${MD_SCOPE[@]}")" ||
    die 'could not parse the Markdown diff'
  MD_CHANGED_LINES="$(list_hunks lines "${MD_SCOPE[@]}")" ||
    die 'could not parse the Markdown diff'
  MD_DELETING_HUNKS="$(list_hunks deletions "${MD_SCOPE[@]}")" ||
    die 'could not parse the Markdown diff'
  # Pair spans at head, as "file\ta\tb". Each pair's own range must also
  # fall inside its file, the same bound check check_artifacts runs for
  # each artifact.
  local spans='' id pfile plines span flen pstart pend records
  records="$(jq --raw-output '.pairs[] | [.id, .file, .lines] | @tsv' "${LEDGER}")" ||
    die "could not read the pair list from ${LEDGER}"
  while IFS=$'\t' read -r id pfile plines; do
    [[ -n ${id} ]] || continue
    is_tracked "${HEAD_REV}" "${pfile}" || {
      finding schema "pair ${id} file ${pfile} is not tracked at the head revision"
      continue
    }
    if ! is_file "${HEAD_REV}" "${pfile}"; then
      finding schema "pair ${id} file ${pfile} is not a file at the head revision"
      continue
    fi
    # Defence in depth: check_schema's rng already rejects a bad range.
    if ! valid_range "${plines}"; then
      finding schema "pair ${id} ${pfile}:${plines} is not a valid <start>-<end> range"
      continue
    fi
    pstart="${plines%-*}"
    pend="${plines#*-}"
    if ((pstart > pend)); then
      finding schema "pair ${id} ${pfile}:${plines} is reversed (start ${pstart} > end ${pend})"
      continue
    fi
    flen="$(line_count "${HEAD_REV}" "${pfile}")"
    if ((pend > flen)); then
      finding schema "pair ${id} ${pfile}:${plines} runs past end of file (${flen} lines)"
      continue
    fi
    span="$(git show "${HEAD_REV}:${pfile}" | paragraph_span "${pstart}" "${pend}")"
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
    # covered: every paragraph the hunk touches has a pair; each one that
    # has none is reported, and the hunk is recorded once as uncovered.
    covered=1
    if ((nl == 0)); then
      if ! span_overlaps "${file}" "${hs}" "${he}" "${spans}"; then
        covered=0
        finding uncovered-hunk "${file}:${hs} changed and no pair covers it"
      fi
    else
      # A hunk can touch more than one HEAD paragraph (e.g. an edit right
      # up against an inserted paragraph with no blank line recorded as
      # context between them); every such paragraph needs its own pair.
      ne=$((ns + nl - 1))
      block_count=0
      while IFS=' ' read -r block_a block_b; do
        [[ -n ${block_a} ]] || continue
        block_count=$((block_count + 1))
        if ! span_overlaps "${file}" "${block_a}" "${block_b}" "${spans}"; then
          covered=0
          finding uncovered-hunk "${file}:${block_a} changed and no pair covers it"
        fi
      done < <(new_side_paragraphs "${file}" "${ns}" "${ne}")
      # The new side is entirely blank/whitespace lines, so there is no
      # paragraph to split on, and covered's default of 1 proves nothing.
      # Like a pure deletion, the hunk anchors on the lines either side of
      # it, hs-1 and he+1, so a pair on the paragraph directly above or
      # below covers it.
      if ((block_count == 0)) && ! span_overlaps "${file}" "$((hs - 1))" "$((he + 1))" "${spans}"; then
        covered=0
        finding uncovered-hunk "${file}:${hs} changed and no pair covers it"
      fi
    fi
    if ((covered)); then
      count_covered "${file}" "${os}" "${ol}" "${ns}" "${nl}"
    else
      UNCOVERED_HUNKS+="${file}"$'\t'"${os}"$'\t'"${ol}"$'\t'"${ns}"$'\t'"${nl}"$'\n'
      # Only a hunk that deletes text is where a removed sibling's text
      # went.
      if grep --line-regexp --fixed-strings --quiet -- "${file}"$'\t'"${os}"$'\t'"${ns}" <<<"${MD_DELETING_HUNKS}"; then
        UNCOVERED_REMOVALS+="${file}"$'\t'"${ns}"$'\t'"${ol}"$'\t'"${nl}"$'\n'
      fi
    fi
  done <<<"${md_hunks}"

  local in_scope
  in_scope="$(changed_names -- "${MD_SCOPE[@]}")" ||
    die 'could not list the changed Markdown files'
  while IFS= read -r changed; do
    [[ -n ${changed} ]] && IN_SCOPE_MD["${changed}"]=1
  done <<<"${in_scope}"

  # Every changed file that is not a surviving Markdown file (a .md name
  # that is still a file at head, not a directory or a gitlink) must be
  # listed. list_hunks diffs with --text, so a surviving .md file git
  # would call binary is still paired per paragraph above; this loop
  # needs no binary case.
  local listed changed changed_files surviving_md
  local -A surviving=()
  listed="$(jq --raw-output '.code_changes[].file' "${LEDGER}")" ||
    die "could not read code_changes from ${LEDGER}"
  changed_files="$(changed_names)" || die 'could not list the changed files'
  surviving_md="$(changed_names -- "${MD_ALL[@]}")" ||
    die 'could not list the changed Markdown files'
  while IFS= read -r changed; do
    [[ -n ${changed} ]] || continue
    if is_file "${HEAD_REV}" "${changed}"; then
      surviving["${changed}"]=1
    fi
  done <<<"${surviving_md}"
  while IFS= read -r changed; do
    [[ -n ${changed} ]] || continue
    [[ -n ${surviving["${changed}"]:-} ]] && continue
    if ! grep --line-regexp --fixed-strings --quiet -- "${changed}" <<<"${listed}"; then
      finding uncovered-file "${changed} is changed but not listed in code_changes"
    fi
  done <<<"${changed_files}"

  ALL_HUNKS="$(list_hunks hunks .)" || die 'could not parse the full diff'
}

# @description True when a hunk of file $1 in the list $4 (list_hunks'
# format) overlaps lines $2..$3.
function hunk_overlaps() {
  local -r file="$1" s="$2" e="$3" hunks="$4"
  local hf ns nl hs he
  while IFS=$'\t' read -r hf _ _ ns nl; do
    [[ ${hf} == "${file}" ]] || continue
    # A pure deletion has no new lines; it touches the boundary at ns/ns+1.
    hs=$((ns > 0 ? ns : 1))
    he=$((nl > 0 ? ns + nl - 1 : ns + 1))
    ((hs <= e && he >= s)) && return 0
  done <<<"${hunks}"
  return 1
}

# @description True when a hunk of file $1 in the list $4 (as
# "file\tns\tol\tnl" lines) reaches lines $2..$3 the way a removed
# sibling is judged. A pure deletion touches the boundary at ns/ns+1. A
# hunk with new lines reaches one past them only when it removed more
# lines than it added (a list item deleted right after its pair's edited
# item); a one-for-one edit deletes nothing there.
function removal_reaches() {
  local -r file="$1" s="$2" e="$3" rows="$4"
  local lf hns hol hnl hs he
  while IFS=$'\t' read -r lf hns hol hnl; do
    [[ ${lf} == "${file}" ]] || continue
    hs=$((hns > 0 ? hns : 1))
    if ((hnl == 0)); then
      he=$((hns + 1))
    elif ((hol > hnl)); then
      he=$((hns + hnl))
    else
      he=$((hns + hnl - 1))
    fi
    ((hs <= e && he >= s)) && return 0
  done <<<"${rows}"
  return 1
}

# @description Exit 0 when stdin lines $1..$2 lie inside one paragraph;
# 1 when one of them is blank, else 2 when one after the first starts a
# list item.
function one_paragraph() {
  awk -v s="$1" -v e="$2" "${PARAGRAPH_AWK}"'
    END {
      mark_paragraphs()
      rc = 0
      for (i = s; i <= e && i <= NR; i++) {
        if (blank[i]) exit 1
        if (i > s && cut[i]) rc = 2
      }
      exit rc
    }'
}

# @description An unchanged sibling must name a range inside its file
# and carry a reason; a sibling marked changed must name a range inside
# one paragraph of its file, apart from its own pair's lines, and a hunk
# must change that range. For a Markdown file in check_completeness'
# scope that means an added line in the range, in a hunk it counted as
# covered, whose words changed: a trailing space, a re-wrap or a
# re-aligned table row is not a fix, and prose inside a generated block
# is fixed at its generator, which is a code change. A
# sibling marked removed names the HEAD position its deleted text sat at,
# at most two lines (a pure deletion's ns or ns+1, so one past the last
# line is allowed), and needs a covered hunk touching it that deletes
# text: a removed line whose collapsed text matches no added line of that
# hunk; a removed sibling in a file the diff deletes needs no hunk, only
# a range inside the file at the merge base. Any
# other file may be cleared by any hunk. A missing lines, status
# or reason field is read as "-": tab is IFS whitespace, so an empty field
# would collapse and shift every field after it. A reason txt reads as
# blank is no reason.
function check_siblings() {
  local id pfile plines file lines status reason s e n ps pe hit lf line limit records
  records="$(jq --raw-output "${JQ_DEFS}"'.pairs[] | .id as $id | .file as $pf | .lines as $pl | .siblings[]
    | [$id, $pf, $pl, .file,
      (if (.lines | type) == "string" and (.lines | length) > 0 then .lines else "-" end),
      (if (.status | type) == "string" and (.status | length) > 0 then .status else "-" end),
      (if .reason | txt then .reason else "-" end)]
    | @tsv' "${LEDGER}")" ||
    die "could not read the sibling list from ${LEDGER}"
  while IFS=$'\t' read -r id pfile plines file lines status reason; do
    [[ -n ${id} ]] || continue
    s=0
    e=0
    if valid_range "${lines}"; then
      s="${lines%-*}"
      e="${lines#*-}"
    fi
    if [[ ${status} == unchanged ]]; then
      # A reason about a file that does not exist at head clears nothing,
      # and one about a range the file does not hold names no text.
      if ! is_tracked "${HEAD_REV}" "${file}"; then
        finding sibling-untracked "pair ${id} sibling ${file} is not tracked at the head revision"
        continue
      elif ! is_file "${HEAD_REV}" "${file}"; then
        finding sibling-untracked "pair ${id} sibling ${file} is not a file at the head revision"
        continue
      fi
      # A range fault is a finding, so the tally below is only ever
      # printed for siblings whose range held.
      if ((s == 0 || s > e)); then
        finding schema "pair ${id} sibling ${file}:${lines} is marked unchanged without a valid <start>-<end> range"
      else
        n="$(line_count "${HEAD_REV}" "${file}")"
        if ((e > n)); then
          finding schema "pair ${id} sibling ${file}:${lines} runs past end of file (${n} lines)"
        fi
      fi
      if [[ ${reason} == - ]]; then
        finding sibling-reason "pair ${id} sibling ${file}:${lines} is unchanged with no reason"
      else
        SIBLINGS_UNCHANGED=$((SIBLINGS_UNCHANGED + 1))
      fi
      continue
    fi
    [[ ${status} == changed || ${status} == removed ]] || continue # check_schema reported the enum
    # A reversed range overlaps nothing, so it would read as "no hunk
    # touches it" rather than as the malformed range it is.
    if ((s == 0 || s > e)); then
      finding schema "pair ${id} sibling ${file}:${lines} is marked ${status} without a valid <start>-<end> range"
      continue
    fi
    # A removed sibling names a deletion boundary (ns, or ns and ns+1),
    # not a span; a wide range would reach any deleting hunk nearby.
    if [[ ${status} == removed ]] && ((e - s > 1)); then
      finding schema "pair ${id} sibling ${file}:${lines} is marked removed with a range wider than a deletion boundary"
      continue
    fi
    # A removed sibling in a file the diff deletes: the file holds a blob
    # at the merge base and nothing at head, so all of its text went and
    # there is no head position to check the range against. The range
    # names the lines the text held at the merge base instead, with no
    # line past the end: a deleted file has no deletion point to anchor
    # one. A file absent at both revisions was never in the diff.
    if [[ ${status} == removed ]] && ! is_tracked "${HEAD_REV}" "${file}"; then
      if is_file "${MB}" "${file}"; then
        n="$(line_count "${MB}" "${file}")"
        if ((e > n)); then
          finding schema "pair ${id} sibling ${file}:${lines} runs past end of file at the merge base (${n} lines)"
        else
          SIBLINGS_REMOVED=$((SIBLINGS_REMOVED + 1))
        fi
      else
        finding sibling-not-removed "pair ${id} sibling ${file}:${lines} is marked removed but is absent at the head revision and not a file at the merge base"
      fi
      continue
    fi
    if is_file "${HEAD_REV}" "${file}"; then
      n="$(line_count "${HEAD_REV}" "${file}")"
      # A deletion at end of file anchors one past the last line.
      limit="${n}"
      if [[ ${status} == removed ]]; then
        limit=$((n + 1))
      fi
      if ((e > limit)); then
        finding schema "pair ${id} sibling ${file}:${lines} runs past end of file (${n} lines)"
        continue
      fi
      # A wide range would be cleared by any hunk it happens to reach. A
      # removed sibling's position may sit on the blank line its text left.
      if [[ ${status} == changed ]] && ! git show "${HEAD_REV}:${file}" | one_paragraph "${s}" "${e}"; then
        finding schema "pair ${id} sibling ${file}:${lines} does not lie within one paragraph"
        continue
      fi
    fi
    # The pair's own fix would otherwise clear its own lines. Only the
    # recorded lines count, not the pair's paragraph: a table row shares a
    # paragraph with its pair, and the gate's hash already covers the rest
    # of that paragraph.
    if [[ ${file} == "${pfile}" ]] && valid_range "${plines}"; then
      ps="${plines%-*}"
      pe="${plines#*-}"
      if ((s <= pe && e >= ps)); then
        finding schema "pair ${id} sibling ${file}:${lines} overlaps its own pair"
        continue
      fi
    fi
    hit=0
    if [[ ${status} == removed ]]; then
      if [[ -n ${IN_SCOPE_MD["${file}"]:-} ]]; then
        removal_reaches "${file}" "${s}" "${e}" "${DELETING_HUNKS}" && hit=1
      elif hunk_overlaps "${file}" "${s}" "${e}" "${ALL_HUNKS}"; then
        hit=1
      fi
      if ((hit)); then
        SIBLINGS_REMOVED=$((SIBLINGS_REMOVED + 1))
      elif removal_reaches "${file}" "${s}" "${e}" "${UNCOVERED_REMOVALS}"; then
        finding sibling-not-removed "pair ${id} sibling ${file}:${lines} is marked removed but the hunk there leaves a paragraph no pair covers (see uncovered-hunk)"
      else
        finding sibling-not-removed "pair ${id} sibling ${file}:${lines} is marked removed but no covered hunk deletes text there"
      fi
      continue
    fi
    if [[ -n ${IN_SCOPE_MD["${file}"]:-} ]]; then
      while IFS=$'\t' read -r lf line; do
        [[ ${lf} == "${file}" ]] || continue
        if ((line >= s && line <= e)); then
          hit=1
          break
        fi
      done <<<"${SUBSTANTIVE_LINES}"
    elif hunk_overlaps "${file}" "${s}" "${e}" "${ALL_HUNKS}"; then
      hit=1
    fi
    if ((hit)); then
      SIBLINGS_CHANGED=$((SIBLINGS_CHANGED + 1))
    elif hunk_overlaps "${file}" "${s}" "${e}" "${UNCOVERED_HUNKS}"; then
      finding sibling-not-changed "pair ${id} sibling ${file}:${lines} is marked changed but the hunk there leaves a paragraph no pair covers (see uncovered-hunk)"
    elif hunk_overlaps "${file}" "${s}" "${e}" "${ALL_HUNKS}"; then
      finding sibling-not-changed "pair ${id} sibling ${file}:${lines} is marked changed but no covered hunk changes its text"
    else
      finding sibling-not-changed "pair ${id} sibling ${file}:${lines} is marked changed but no hunk touches it"
    fi
  done <<<"${records}"
}

# @description Print the head line that merge-base line $2 of file $1
# maps to, through ALL_HUNKS; side $3 is "first" or "last" of the span a
# replaced line maps to. A line a hunk replaced maps to the hunk's new
# side, reaching one line past it when the hunk removed more lines than
# it added, as a removed sibling's reach does. A line removed by a pure
# deletion, or replaced only by blank lines, maps to the lines either
# side of the hunk, where completeness anchors that hunk. Any other line
# moves by the lines the hunks above it added or removed.
function head_line() {
  local -r file="$1" line="$2" side="$3"
  local hf os ol ns nl delta=0
  while IFS=$'\t' read -r hf os ol ns nl; do
    [[ ${hf} == "${file}" ]] || continue
    if ((ol > 0 && line >= os && line <= os + ol - 1)); then
      if ((nl > 0)) && all_blank "${HEAD_REV}" "${file}" "${ns}" $((ns + nl - 1)); then
        if [[ ${side} == first ]]; then
          printf '%d\n' $((ns > 1 ? ns - 1 : 1))
        else
          printf '%d\n' $((ns + nl))
        fi
      elif [[ ${side} == first ]]; then
        printf '%d\n' $((ns > 0 ? ns : 1))
      elif ((nl == 0)); then
        printf '%d\n' $((ns + 1))
      elif ((ol > nl)); then
        printf '%d\n' $((ns + nl))
      else
        printf '%d\n' $((ns + nl - 1))
      fi
      return 0
    fi
    if (((ol > 0 && os + ol - 1 < line) || (ol == 0 && os < line))); then
      delta=$((delta + nl - ol))
    fi
  done <<<"${ALL_HUNKS}"
  printf '%d\n' $((line + delta))
}

SWEEP_TERMS=0
SWEEP_CLEARED=0

# @description Each finding needs a pair carrying a sweep term, and every
# hit of a pair's terms at the merge base must sit in that pair's own
# paragraph or one of its sibling ranges (any status), once mapped to
# head with head_line. A hit in a file that is not a file at head keeps
# its merge-base lines, which is where a removed sibling in a deleted
# file points. A term with no hit at all is reported: it is not the old
# wording as the sweep reads it (a misspelling, or text the sweep skips).
function check_sweeps() {
  local missing fnum ids records k id pfile plines term hits f s e a b where span
  missing="$(jq --raw-output "${JQ_DEFS}"'[.pairs[]] | group_by(.finding)[]
    | select(all(.[]; (.sweep | arr | length) == 0))
    | [(.[0].finding | tojson), (map("\(.id) at \(.file):\(.lines)") | join(", "))] | @tsv' "${LEDGER}")" ||
    die "could not read the sweep terms from ${LEDGER}"
  while IFS=$'\t' read -r fnum ids; do
    [[ -n ${fnum} ]] || continue
    finding missing-sweep "finding ${fnum} has no pair carrying a sweep term (pairs ${ids})"
  done <<<"${missing}"

  # Pairs by index, then terms by pair index: a term is read raw, one per
  # line (check_schema confined it to no newline, tab or CR), so a
  # backslash in it is not doubled the way @tsv would double it.
  local -a pid=() pf=() pl=()
  records="$(jq --raw-output '.pairs | to_entries[] | [(.key | tostring), .value.id, .value.file, .value.lines] | @tsv' "${LEDGER}")" ||
    die "could not read the pair list from ${LEDGER}"
  while IFS=$'\t' read -r k id pfile plines; do
    [[ -n ${k} ]] || continue
    pid[k]="${id}"
    pf[k]="${pfile}"
    pl[k]="${plines}"
  done <<<"${records}"
  local terms
  terms="$(jq --raw-output "${JQ_DEFS}"'.pairs | to_entries[] | .key as $k
    | (.value.sweep | arr)[] | [($k | tostring), .] | join("\t")' "${LEDGER}")" ||
    die "could not read the sweep terms from ${LEDGER}"
  local -A seen=()
  while IFS=$'\t' read -r k term; do
    [[ -n ${k} ]] || continue
    SWEEP_TERMS=$((SWEEP_TERMS + 1))
    # The entries that clear a hit: the pair's own paragraph at head and
    # each sibling range, as "file\tstart\tend".
    local entries=''
    if is_file "${HEAD_REV}" "${pf[k]}" && valid_range "${pl[k]}"; then
      span="$(git show "${HEAD_REV}:${pf[k]}" | paragraph_span "${pl[k]%-*}" "${pl[k]#*-}")"
      entries+="${pf[k]}"$'\t'"${span% *}"$'\t'"${span#* }"$'\n'
    fi
    local sfile slines
    while IFS=$'\t' read -r sfile slines; do
      [[ -n ${sfile} ]] || continue
      valid_range "${slines}" || continue
      entries+="${sfile}"$'\t'"${slines%-*}"$'\t'"${slines#*-}"$'\n'
    done < <(jq --raw-output --argjson k "${k}" '.pairs[$k].siblings[] | [.file, (.lines // "-")] | @tsv' "${LEDGER}")
    hits="$(sweep_hits "${term}")" || die "could not sweep the term ${term}"
    if [[ -z ${hits} ]]; then
      finding sweep-empty "pair ${pid[k]} term \"${term}\" matches nothing in the sweep scope at the merge base"
      continue
    fi
    while IFS=$'\t' read -r f s e _; do
      [[ -n ${f} ]] || continue
      [[ -z ${seen["${k}"$'\t'"${f}:${s}-${e}"]:-} ]] || continue
      seen["${k}"$'\t'"${f}:${s}-${e}"]=1
      if is_file "${HEAD_REV}" "${f}"; then
        a="$(head_line "${f}" "${s}" first)"
        b="$(head_line "${f}" "${e}" last)"
        where="${a}-${b} at head"
      else
        a="${s}"
        b="${e}"
        where='deleted at head'
      fi
      if span_overlaps "${f}" "${a}" "${b}" "${entries}"; then
        SWEEP_CLEARED=$((SWEEP_CLEARED + 1))
      else
        finding sweep-uncovered "pair ${pid[k]} term \"${term}\" hits ${f}:${s}-${e} at the merge base (${where}) and no entry of the pair covers it"
      fi
    done <<<"${hits}"
  done <<<"${terms}"
}

# @description Every pair needs a gate verdict of TRUE whose hash still
# matches the pair's whole paragraph at head, and every code change needs a
# gate entry recording an attack and its result, neither blank to txt,
# against the blob the file holds at head.
# A pair whose own file or range check_completeness already rejected is
# skipped here, since there is no paragraph to hash. Missing verdict, hash or
# note fields are read as "-", for the same IFS reason check_siblings
# gives.
function check_verdicts() {
  local id file lines verdict hash note current n start end records changed
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
    if [[ ${verdict} == TRUE && ${hash} == - ]]; then
      finding missing-hash "pair ${id} has a TRUE verdict with no hash"
      continue
    fi
    # The paragraph's hash now, or empty when there is no hash to compare
    # or no paragraph to hash.
    current=''
    if [[ ${hash} != - ]] && is_file "${HEAD_REV}" "${file}" && valid_range "${lines}"; then
      start="${lines%-*}"
      end="${lines#*-}"
      n="$(line_count "${HEAD_REV}" "${file}")"
      if ((start >= 1 && start <= end && end <= n)); then
        current="$(paragraph_hash "${HEAD_REV}" "${file}" "${start}" "${end}")"
      fi
    fi
    if [[ ${verdict} != TRUE ]]; then
      # A note the gate wrote about text since edited must not read as a
      # verdict on the new text.
      changed=''
      if [[ -n ${current} && ${current} != "${hash}" ]]; then
        changed=' (paragraph changed since the gate read it)'
      fi
      if [[ ${note} == - ]]; then
        finding verdict "pair ${id} is ${verdict}${changed}"
      else
        finding verdict "pair ${id} is ${verdict}: ${note}${changed}"
      fi
      continue
    fi
    [[ -z ${current} || ${current} == "${hash}" ]] ||
      finding stale-verdict "pair ${id} ${file}:${lines} changed after the gate read it"
  done <<<"${records}"

  local cfile unattacked attacked blobs current_blob
  unattacked="$(jq --raw-output --slurpfile gate "${GATE}" "${JQ_DEFS}"'
    .code_changes[].file as $f
    | select(any($gate[0].code_changes[];
      .file == $f and (.attack | txt) and (.result | txt)) | not)
    | $f' "${LEDGER}")" ||
    die "could not read the gate attacks from ${GATE}"
  while IFS= read -r cfile; do
    [[ -n ${cfile} ]] || continue
    finding missing-attack "code change ${cfile} has no gate attack and result"
  done <<<"${unattacked}"

  # An attack holds only for the blob it ran against: a code change edited
  # after the gate attacked it is stale, as a paragraph edited after the
  # gate read it is. Each attacked file is printed with the blobs of its
  # attacked gate entries, space-separated (check_gate_schema has already
  # confined every blob to hex or "deleted").
  attacked="$(jq --raw-output --slurpfile gate "${GATE}" "${JQ_DEFS}"'
    .code_changes[].file as $f
    | [$gate[0].code_changes[]
      | select(.file == $f and (.attack | txt) and (.result | txt)) | .blob]
    | select(length > 0)
    | [$f, join(" ")] | @tsv' "${LEDGER}")" ||
    die "could not read the gate attack blobs from ${GATE}"
  while IFS=$'\t' read -r cfile blobs; do
    [[ -n ${cfile} ]] || continue
    current_blob="$(git rev-parse --verify --quiet "${HEAD_REV}:${cfile}")" ||
      current_blob=deleted
    if [[ " ${blobs} " != *" ${current_blob} "* ]]; then
      finding stale-attack "code change ${cfile} changed after the gate attacked it (attacked ${blobs}; head holds ${current_blob})"
    fi
  done <<<"${attacked}"
}

function main() {
  local class detail schema_bad=0 schema npairs nchanges ncommands
  # Even with core.quotePath=false, git C-quotes a path holding a double
  # quote, a backslash or a control character, in the diff headers and
  # name lists this script reads alike. No ledger name matches the quoted
  # spelling except one written as that quoted text, which would then
  # pass a code change whose attack names no blob. A quoted name always
  # starts with a double quote and a plain one never can, so the check is
  # on the first character; the name is shown as git prints it.
  local changed_all quoted
  changed_all="$(changed_names)" || die 'could not list the changed files'
  while IFS= read -r quoted; do
    if [[ ${quoted} == \"* ]]; then
      die "cannot check the change to ${quoted}: git quotes a path holding a double quote, backslash or control character; rename it"
    fi
  done <<<"${changed_all}"
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
    check_anchors
    check_completeness
    check_siblings
    check_sweeps
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
  ncommands="$(jq "${JQ_DEFS}"'[.pairs[].artifact[] | select(iscmd)] | length' "${LEDGER}")" ||
    die "could not count command artifacts in ${LEDGER}"
  # The command tally is printed only when there is one, so a ledger
  # citing no command keeps the OK line it always had.
  local command_note=''
  if ((ncommands > 0)); then
    command_note="; ${ncommands} command artifacts, shape-checked only"
  fi
  # Likewise the sweep tally, printed only for a ledger with terms, which
  # is every ledger with a pair.
  local sweep_note=''
  if ((SWEEP_TERMS > 0)); then
    sweep_note="; ${SWEEP_TERMS} sweep terms, ${SWEEP_CLEARED} hits cleared"
  fi
  printf '%s: OK — %d pairs; %d hunks covered, %d reflow-only and %d generated skipped; %d code changes; %d changed, %d unchanged and %d removed siblings%s%s\n' \
    "${PROG}" "${npairs}" "${HUNKS_COVERED}" "${HUNKS_REFLOW}" "${HUNKS_GENERATED}" "${nchanges}" \
    "${SIBLINGS_CHANGED}" "${SIBLINGS_UNCHANGED}" "${SIBLINGS_REMOVED}" "${command_note}" "${sweep_note}"
}

main
