# scripts/_attestation_invocations.awk
#
# Emits one record per `gh attestation verify` invocation found in the
# input, tab-prefixed with its pin status.
#
# Invoked as:
#   awk -v mode=md|other -v slug=<owner/repo> --file <this> <input>
#
# Output, one line per record:
#   ok\t<record>    the record carries --repo <slug> or --repo=<slug>
#   bad\t<record>   it does not
#
# A record is the space-joined shell words of one invocation, running
# from the `gh attestation verify` word triple to the next unquoted
# shell separator or comment, or to the end of the string. Binding the
# pin to a word position rather than substring-matching the record is
# what stops a trailing comment or a neighbouring command from vouching
# for an unpinned invocation.
#
# The command is a word triple, never a literal string, so any run of
# whitespace between the words matches.

BEGIN {
  if (slug == "") {
    print "_attestation_invocations.awk: -v slug is required" > "/dev/stderr"
    exit 2
  }
  if (mode != "md" && mode != "other") {
    print "_attestation_invocations.awk: -v mode must be md or other" > "/dev/stderr"
    exit 2
  }
  carry_open = 0
  carry_text = ""
  carry_runnable = 0
  nrun = 0
  in_fence = 0
  fence_char = ""
  fence_len = 0
  fence_runnable = 0
}

# Split `s` into shell words. Fills out[1..n] with word text and
# typ[1..n] with the word kind:
#   w    ordinary word
#   sep  unquoted ; && || | &
#   cmt  unquoted # beginning a word; holds the rest of `s` and is last
# Returns n.
function tokenize(s, out, typ,   n, i, c, cur, has, L) {
  n = 0
  cur = ""
  has = 0
  i = 1
  L = length(s)
  while (i <= L) {
    c = substr(s, i, 1)
    if (c == " " || c == "\t") {
      if (has) { out[++n] = cur; typ[n] = "w"; cur = ""; has = 0 }
      i++
      continue
    }
    if (c == "'") {
      # Single quotes: everything up to the next quote is literal. An
      # unterminated quote swallows the rest of the string as one word.
      has = 1
      i++
      while (i <= L && substr(s, i, 1) != "'") { cur = cur substr(s, i, 1); i++ }
      i++
      continue
    }
    if (c == "\"") {
      has = 1
      i++
      while (i <= L && substr(s, i, 1) != "\"") {
        if (substr(s, i, 1) == "\\" && i < L) i++
        cur = cur substr(s, i, 1)
        i++
      }
      i++
      continue
    }
    if (c == "\\") {
      if (i < L) { i++; cur = cur substr(s, i, 1); has = 1 }
      i++
      continue
    }
    if (c == "`") {
      # Legacy command substitution in shell, literal payload inside a
      # longer code span. Either way it delimits words rather than
      # joining them.
      if (has) { out[++n] = cur; typ[n] = "w"; cur = ""; has = 0 }
      i++
      continue
    }
    if (c == "#" && !has) {
      # A `#` only opens a comment at the start of a word.
      out[++n] = substr(s, i)
      typ[n] = "cmt"
      return n
    }
    if (c == ";" || c == "&" || c == "|") {
      if (has) { out[++n] = cur; typ[n] = "w"; cur = ""; has = 0 }
      if (substr(s, i, 2) == "&&" || substr(s, i, 2) == "||") {
        out[++n] = substr(s, i, 2)
        i += 2
      } else {
        out[++n] = c
        i++
      }
      typ[n] = "sep"
      continue
    }
    cur = cur c
    has = 1
    i++
  }
  if (has) { out[++n] = cur; typ[n] = "w" }
  return n
}

# Emit every `gh attestation verify` invocation carried by `s`.
#
# A record runs from the command triple to the next separator or comment
# token, or to the end of the word list. `mention_ok` is 1 for text that
# came from a code span, where a bare triple with no further word is a
# prose mention rather than an invocation; it is 0 for text that came
# from a runnable source line, where a bare triple is an unpinned
# invocation.
function emit_records(s, mention_ok,   out, typ, n, i, j, extra, rec, pinned) {
  n = tokenize(s, out, typ)
  for (i = 1; i + 2 <= n; i++) {
    if (typ[i] != "w" || out[i] != "gh") continue
    if (typ[i + 1] != "w" || out[i + 1] != "attestation") continue
    if (typ[i + 2] != "w" || out[i + 2] != "verify") continue
    rec = "gh attestation verify"
    extra = 0
    pinned = 0
    for (j = i + 3; j <= n; j++) {
      if (typ[j] != "w") break
      rec = rec " " out[j]
      extra++
      if (out[j] == "--repo=" slug) pinned = 1
      else if (out[j] == "--repo" && j < n && typ[j + 1] == "w" && out[j + 1] == slug) pinned = 1
    }
    # Resume scanning at the token that ended this record, so a chained
    # command is judged on its own arguments.
    i = j - 1
    if (mention_ok && extra == 0) continue
    print (pinned ? "ok" : "bad") "\t" rec
  }
}

# Buffer a runnable source string for the backslash join in flush_runnable.
function push_runnable(s) {
  runnable_lines[++nrun] = s
}

# Scan `s` for code spans. A run of N backticks opens a span; the next
# run of exactly N closes it. A run of any other length inside an open
# span is literal content, which is what lets a doubled-backtick span
# carry a single-backtick span as payload.
#
# Sets the global `strip_line` to the text outside spans, so a caller
# processing a runnable line can tokenize it without the quoted
# occurrences it has already accounted for here.
#
# `runnable` records whether the span was opened on a runnable line; see
# kill_carry.
function scan_spans(s, runnable,   i, run, L) {
  strip_line = ""
  i = 1
  L = length(s)
  while (i <= L) {
    if (substr(s, i, 1) != "`") {
      if (carry_open > 0) carry_text = carry_text substr(s, i, 1)
      else strip_line = strip_line substr(s, i, 1)
      i++
      continue
    }
    run = 0
    while (i + run <= L && substr(s, i + run, 1) == "`") run++
    if (carry_open == 0) {
      carry_open = run
      carry_text = ""
      carry_runnable = runnable
    } else if (run == carry_open) {
      emit_records(carry_text, 1)
      carry_open = 0
      carry_text = ""
    } else {
      carry_text = carry_text substr(s, i, run)
    }
    i += run
  }
  # A span still open at end of line continues onto the next one; the
  # newline joins as a space.
  if (carry_open > 0) carry_text = carry_text " "
}

# An unresolved span dies at a blank line or at EOF — CommonMark forbids
# a blank line inside a code span. Its text was literal, not a span.
#
# Text that came from a runnable line must go back into the runnable
# stream, or an unterminated backtick would swallow the invocation it
# contains. Text from a prose line is discarded: prose contributes only
# completed spans.
function kill_carry(   t) {
  if (carry_open == 0) return
  t = carry_text
  carry_open = 0
  carry_text = ""
  if (carry_runnable) push_runnable(t)
}

# The fence language: the first word of the info string, with Pandoc-style
# attribute punctuation stripped. `{.sh}` and `{.bash .numberLines}` are
# ordinary in generated markdown and must not read as an unknown language.
function normalize_info(t) {
  sub(/^[[:space:]]+/, "", t)
  sub(/[[:space:]].*$/, "", t)
  sub(/^\{/, "", t)
  sub(/^\./, "", t)
  sub(/\}$/, "", t)
  return t
}

# sh/bash/shell/console/text and unlabeled fences are shell source.
# Everything else is a diagram and is skipped entirely.
function lang_runnable(l) {
  return (l == "" || l == "sh" || l == "bash" || l == "shell" \
    || l == "console" || l == "text")
}

# Does `line` open a fence? Records the fence character and run length so
# a backtick run cannot close a tilde fence and vice versa.
function is_fence_open(line,   t, ch, len, info) {
  if (line !~ /^[[:space:]]*(```|~~~)/) return 0
  t = line
  sub(/^[[:space:]]*/, "", t)
  ch = substr(t, 1, 1)
  len = 0
  while (substr(t, len + 1, 1) == ch) len++
  info = substr(t, len + 1)
  # CommonMark forbids a backtick in a backtick fence's info string. Without
  # this, a line-leading inline code span reads as a fence opener and every
  # later fence on the page is tracked inverted.
  if (ch == "`" && index(info, "`") > 0) return 0
  fence_char = ch
  fence_len = len
  fence_runnable = lang_runnable(normalize_info(info))
  in_fence = 1
  return 1
}

# Does `line` close the open fence? Same character, a run at least as long
# as the opener, and nothing but whitespace after it.
function is_fence_close(line,   t, len) {
  if (line !~ /^[[:space:]]*(```|~~~)/) return 0
  t = line
  sub(/^[[:space:]]*/, "", t)
  if (substr(t, 1, 1) != fence_char) return 0
  len = 0
  while (substr(t, len + 1, 1) == fence_char) len++
  if (len < fence_len) return 0
  return (substr(t, len + 1) ~ /^[[:space:]]*$/)
}

# Join buffered runnable strings on a trailing backslash, then emit the
# records each joined string carries.
#
# The join runs before tokenizing, so a backslash-newline inside single
# quotes joins where real shell would keep it literal. That is the
# permissive direction and cannot hide an invocation.
function flush_runnable(   i, j, joined) {
  for (i = 1; i <= nrun; i++) {
    joined = runnable_lines[i]
    j = i
    while (joined ~ /\\[[:space:]]*$/ && j < nrun) {
      sub(/\\[[:space:]]*$/, "", joined)
      j++
      joined = joined " " runnable_lines[j]
    }
    i = j
    emit_records(joined, 0)
  }
  nrun = 0
}

# Dispatch each line to the right source treatment: markdown fence and
# indent state in md mode, comment skip in yml/sh. Runnable lines are
# span-scanned and buffered for the backslash join; prose contributes
# only its code spans.
{
  if ($0 ~ /^[[:space:]]*$/) kill_carry()

  if (mode == "md") {
    if (in_fence) {
      if (is_fence_close($0)) { in_fence = 0; next }
      if (!fence_runnable) next
      scan_spans($0, 1)
      push_runnable(strip_line)
      next
    }
    if (is_fence_open($0)) next
    # An indented code block. The repo has none today, and only a line
    # carrying the command outside a span can produce a record, so the
    # simple rule costs nothing that CommonMark container tracking buys.
    if ($0 ~ /^(    |\t)/) {
      scan_spans($0, 1)
      push_runnable(strip_line)
      next
    }
    # Prose. An inline code span is the only runnable shape here.
    scan_spans($0, 0)
    next
  }

  # yml/sh: a comment line is prose whatever it quotes. This skip must
  # precede the span scan — a comment can carry a backticked command with
  # an elided argument, which the span rule would read as an invocation.
  if ($0 ~ /^[[:space:]]*#/) next
  scan_spans($0, 1)
  push_runnable(strip_line)
}

END {
  kill_carry()
  flush_runnable()
}
