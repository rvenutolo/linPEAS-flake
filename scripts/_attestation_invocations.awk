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

# Temporary driver, replaced in Task 2. Treats every input line as a
# runnable shell line so the tokenizer can be exercised on its own.
{
  n = tokenize($0, w, t)
  for (i = 1; i + 2 <= n; i++) {
    if (t[i] != "w" || w[i] != "gh") continue
    if (t[i + 1] != "w" || w[i + 1] != "attestation") continue
    if (t[i + 2] != "w" || w[i + 2] != "verify") continue
    rec = "gh attestation verify"
    pinned = 0
    for (j = i + 3; j <= n; j++) {
      if (t[j] != "w") break
      rec = rec " " w[j]
      if (w[j] == "--repo=" slug) pinned = 1
      else if (w[j] == "--repo" && j < n && t[j + 1] == "w" && w[j + 1] == slug) pinned = 1
    }
    i = j - 1
    print (pinned ? "ok" : "bad") "\t" rec
  }
}
