# scripts/lib/md-fence.sh
#
# @description One Markdown fence reader for the lints that read shell
# commands inside fences, as `awk` source to place ahead of the caller's
# program. Source after `set -Eeuo pipefail`.
# shellcheck shell=bash

# The `awk` function `md_step(line)` classifies each line of one file, fed
# in order, and keeps the fence state between calls:
#
#   0  outside any fence (prose)
#   1  a fence opens on this line
#   2  a content line inside a fence
#   3  the fence closes on this line
#
# A fence opens on a run of three or more backticks or tildes, after any
# indentation, blockquote markers and list markers; a backtick fence's tag
# holds no backtick. It closes on a run of the same character at least as
# long, with nothing after it, at the same blockquote depth. A line at a
# shallower blockquote depth ends the fence first (`md_closed` is 1 for
# that call, and the line is then classified in the new state). A file
# that ends inside a fence leaves it open: the caller sees `md_in` still 1
# in `END`.
#
# On a content line `md_text` is the line without the blockquote markers
# that belong to the fence. After an opening line `md_lang` is the first
# word of the info string, lower-cased, with attribute braces and a
# leading dot removed (`{.sh}` reads as `sh`; a tag after a space reads as
# the tag, not as empty), `md_start` is the line number, and `md_read` is 1
# when that tag is empty or one of sh/bash/shell/console/text.
#
# Trailing carriage returns are dropped before classification, so a file
# with CRLF line endings reads as the same fences, and indentation, the
# gap before a tag and trailing text count any `[[:space:]]` as blank.
#
# Indentation is uncapped and a list item ending does not close a fence
# opened on its marker line; a fence the Markdown renderer would end
# early stays open here until a matching closer. `sub` is used instead of
# `match`, so the caller's `RSTART` and `RLENGTH` survive a call.
# The variable is read by the sourcing script, and the program holds `$`
# characters that must reach `awk` unexpanded.
# shellcheck disable=SC2034,SC2016
readonly MD_FENCE_AWK='
function md_step(line,    t, q, u, ch, n, rest, info, w, again) {
  sub(/\r+$/, "", line)
  md_closed = 0
  md_text = line
  t = line
  q = 0
  if (md_in) {
    while (q < md_depth && t ~ /^[[:space:]]*>/) { sub(/^[[:space:]]*>[ ]?/, "", t); q++ }
    if (q < md_depth) { md_in = 0; md_closed = 1; t = line; q = 0 }
  }
  if (!md_in) {
    again = 1
    while (again) {
      again = 0
      if (t ~ /^[[:space:]]*>/) { sub(/^[[:space:]]*>[ ]?/, "", t); q++; again = 1 }
      else if (t ~ /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+/) {
        sub(/^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+/, "", t); again = 1
      }
    }
  }
  u = t
  sub(/^[[:space:]]*/, "", u)
  ch = substr(u, 1, 1)
  n = 0
  if (ch == "`" || ch == "~") { while (substr(u, n + 1, 1) == ch) n++ }
  rest = substr(u, n + 1)
  if (md_in) {
    if (n >= 3 && ch == md_ch && n >= md_len && rest ~ /^[[:space:]]*$/) {
      md_in = 0
      return 3
    }
    md_text = t
    return 2
  }
  if (n >= 3 && !(ch == "`" && index(rest, "`"))) {
    md_in = 1
    md_ch = ch
    md_len = n
    md_depth = q
    md_start = NR
    info = rest
    gsub(/[{}]/, " ", info)
    sub(/^[[:space:]]+/, "", info)
    sub(/[[:space:]].*$/, "", info)
    sub(/^[.]/, "", info)
    md_lang = tolower(info)
    md_read = (md_lang == "" || md_lang == "sh" || md_lang == "bash" \
      || md_lang == "shell" || md_lang == "console" || md_lang == "text")
    return 1
  }
  return 0
}
'
