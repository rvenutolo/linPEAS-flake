# scripts/lib/hook-filter.sh
#
# @description Read a git-hooks.nix hook block's `files` and `excludes`
# filters from source, and decide whether they admit a path the way
# pre-commit decides it: with Python `re.search`, admitting a path when
# `files` matches it and the `exclude` pattern pre-commit receives does
# not. Never POSIX ERE: the hook modules use lookaheads, which ERE lacks,
# and grep reads such a pattern as one that matches nothing, a verdict
# about a hook pre-commit does run. Source after `set -Eeuo pipefail`.
# shellcheck shell=bash

# awk functions that collect a hook block's filters, for a caller to put
# ahead of its own block parser in one awk program. The caller calls
# `hook_filter_reset()` where a block opens, `hook_filter_scan($0)` on
# every line inside it, and reads `hook_filter_files` and
# `hook_filter_exclude()` where it closes.
#
# `hook_filter_files` is the `files` value as written in the Nix source,
# escapes included. `hook_filter_exclude()` is what pre-commit receives:
# the `excludes` list joined the way git-hooks.nix joins it, `(a|b)`,
# else pre-commit's default `^$`. git-hooks.nix has no singular `exclude`
# option. A list may span lines, and its end is a `]` outside every
# quoted entry, since an entry can hold a bracket expression of its own.
#
# `hook_filter_scan` runs `match()`, so a caller reads RSTART and RLENGTH
# from its own matches only after the call. The program text is indented
# so that no line of it reads as a shell `function name()` definition to
# the scripts-reference parser.
# shellcheck disable=SC2016,SC2034 # awk program text whose $0 is awk's; read by the sourcing script
readonly HOOK_FILTER_AWK='
  function hook_filter_reset() {
    hook_filter_files = ""
    hook_filter_excludes = ""
    hook_filter_in_excludes = 0
  }
  function hook_filter_scan(line,    s, list, tok) {
    if (match(line, /files = "[^"]*"/)) {
      s = substr(line, RSTART, RLENGTH)
      sub(/^files = "/, "", s)
      sub(/"$/, "", s)
      hook_filter_files = s
    }
    list = ""
    if (hook_filter_in_excludes) {
      list = line
    } else if (match(line, /excludes = \[/)) {
      list = substr(line, RSTART + RLENGTH)
      hook_filter_in_excludes = 1
    }
    if (hook_filter_in_excludes) {
      while (match(list, /"[^"]*"/)) {
        tok = substr(list, RSTART + 1, RLENGTH - 2)
        hook_filter_excludes = (hook_filter_excludes == "" ? tok : hook_filter_excludes "|" tok)
        list = substr(list, RSTART + RLENGTH)
      }
      if (list ~ /\]/) hook_filter_in_excludes = 0
    }
  }
  function hook_filter_exclude() {
    return (hook_filter_excludes == "" ? "^$" : "(" hook_filter_excludes ")")
  }
'

# The matcher behind `hook_filter_admits`. A pattern is a Nix string
# literal, so its escapes are undone first, which turns the source's
# `\\.` into the `\.` pre-commit receives. Every pattern that does not
# compile is named once per hook before the program exits 2, and then
# nothing is printed: a verdict about such a hook would be a guess.
readonly HOOK_FILTER_PROGRAM='
import re
import sys

NIX_ESCAPES = {"n": "\n", "r": "\r", "t": "\t"}


def unescape(literal):
    return re.sub(r"\\(.)", lambda m: NIX_ESCAPES.get(m.group(1), m.group(1)), literal)


prefix = sys.argv[1]
data = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
records = data.split("\0")
if records and records[-1] == "":
    records.pop()

compiled = {}
reported = set()
failed = False
verdicts = []
for record in records:
    fields = record.split("\x1f", 3)
    if len(fields) != 4:
        print(f"{prefix}: hook-filter record has {len(fields)} field(s), want 4", file=sys.stderr)
        sys.exit(2)
    name, files, exclude, path = fields
    patterns = {}
    for key, literal in (("files", files), ("exclude", exclude)):
        if literal not in compiled:
            try:
                compiled[literal] = re.compile(unescape(literal))
            except re.error as err:
                compiled[literal] = err
        pattern = compiled[literal]
        if isinstance(pattern, re.error):
            if (name, key) not in reported:
                reported.add((name, key))
                print(
                    f"{prefix}: hook {name}: its {key} pattern does not compile under Python re: {pattern}",
                    file=sys.stderr,
                )
            failed = True
        else:
            patterns[key] = pattern
    if len(patterns) < 2:
        continue
    admitted = patterns["files"].search(path) and not patterns["exclude"].search(path)
    verdicts.append("true" if admitted else "false")
if failed:
    sys.exit(2)
for verdict in verdicts:
    print(verdict)
'

# @description Decide, for each query on stdin, whether a hook's filters
# admit a path, as pre-commit decides it. A query is one NUL-terminated
# record of four fields separated by an ASCII unit separator (`\037`):
# hook name, `files` value as written in the Nix source, the joined
# exclude pattern (`hook_filter_exclude()` in `HOOK_FILTER_AWK`), and the
# path. The path is the last field and NUL ends the record, so a path may
# hold any other byte, a newline included.
#
# The verdicts are all or nothing: when any pattern does not compile,
# each such hook is named on stderr and nothing is printed, so a caller
# cannot score part of a set. python3 is guarded here rather than at
# each call site, so a caller that lacks it learns that by name.
# @arg $1 diagnostic prefix, conventionally the caller's lint name
# @stdout one line per query, in query order: `true` when the hook's
#   filters admit the path, `false` when they do not
# @exitcode 0 every query was decided
# @exitcode 2 python3 is missing, a query is malformed, or a pattern
#   does not compile
function hook_filter_admits() {
  local -r prefix="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    printf '%s: missing required tool: python3\n' "${prefix}" >&2
    return 2
  fi
  python3 -I -c "${HOOK_FILTER_PROGRAM}" "${prefix}" || return 2
}
