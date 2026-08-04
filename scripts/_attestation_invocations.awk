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

# Temporary driver, replaced in Task 5. Treats every input line as a
# runnable shell line.
{ emit_records($0, 0) }
