# scripts/_attestation_invocations.awk
#
# Emits one record per `gh attestation verify` invocation found in the
# input, tab-prefixed with its pin status.
#
# Invoked as:
#   awk -v mode=md|other -v slug=<owner/repo> --file <this> <input>
#
# Output, one line per record:
#   ok\t<record>    the record carries --repo/-R <slug>, --repo=/-R=<slug>, or -R<slug>
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
#
# A quoted region preceded by a command introducer — a key whose value is a
# command line, the word `eval`, or a flag taking a command argument — is also
# re-parsed as a command source, so an invocation written inside one pair of
# quotes does not collapse into a single word. See is_introducer.

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
  fence_lang = ""
  fence_runnable = 0
  npay = 0
}

# Is the quoted region about to be read a command source rather than an
# argument? `cur` is the partial word built so far, `n` and `out` the words
# already emitted.
#
# A quoted region is ordinarily literal word text, which is right for shell:
# `"a b"` is one argument. Where the quotes are YAML or nix syntax the payload
# is a command line instead, and collapsing it into a single word hides the
# invocation it carries. Command position separates the two, and it is
# readable from the text immediately before the opening quote.
function is_introducer(cur, n, out, typ, cmdstart, wdepth, wgroup, gkind, cd,   prev) {
  # Set as a side effect for the caller to read via the global
  # `intro_kind`: "eval" when the match was specifically the bare word
  # `eval`, empty otherwise. See push_payload and the drain in
  # emit_records, which use it to judge an eval payload followed by a
  # further word as an invocation — eval concatenates its arguments into
  # one command line, so the artifact can sit outside the quotes.
  intro_kind = ""
  # A quote glued to its key: `run:"…"`, `entry="…"`, or to a flag inside
  # flow-syntax punctuation: `{run:"…"`, `-c,"…"`. `bare` is 0 here: a
  # glued word with no `:`/`=` is ordinary text, e.g. `npm run"…"` in
  # nobody's syntax, not this key.
  if (cur != "") {
    cur = strip_structural(cur)
    # `$'…'` (ANSI-C quoting) and `$"…"` (locale quoting) are shell syntax
    # for the quote itself, not part of the preceding word — a trailing
    # `$` glued to an introducer, e.g. `eval $'…'`, must not hide it.
    # Stripping it can empty `cur`, which is what lets this fall through
    # to the previous-word path below.
    sub(/\$$/, "", cur)
  }
  if (cur != "") {
    if (cur == "eval") intro_kind = "eval"
    return (introducer_key(cur, 0) \
      || introducer_word(cur, out, typ, cmdstart, wdepth, wgroup, gkind, cd, n))
  }
  prev = (n >= 1 ? strip_structural(out[n]) : "")
  # A nix attribute assignment: `entry = "…"`. Reading past the `=` to the
  # attribute name is what keeps a prose string such as
  # `description = "…"` literal word text. The attribute name is bare here
  # (no trailing punctuation of its own), which is why this is the only
  # path introducer_key is asked to accept one.
  if (prev == "=") return introducer_key(n >= 2 ? strip_structural(out[n - 1]) : "", 1)
  if (prev == "eval") intro_kind = "eval"
  return (introducer_key(prev, 0) \
    || introducer_word(prev, out, typ, cmdstart, wdepth, wgroup, gkind, cd, n - 1))
}

# An attribute or mapping key whose value is a command line, in either the
# YAML `key:` or the nix `key =` form. `bare` is 1 only for the nix
# lookback past an `=`, where the attribute name legitimately carries no
# trailing punctuation; everywhere else a bare word such as a `run`
# subcommand argument must not read as this key.
function introducer_key(w, bare) {
  if (!bare && w !~ /[:=]$/) return 0
  sub(/[:=]$/, "", w)
  return (w == "run" || w == "entry" || w == "text" || w == "script" \
    || w == "command" || w == "cmd" || w == "entrypoint" || w == "shell")
}

# A command word or flag whose next argument is a command line. `--command`
# accepts an optional trailing `=`, matching the glued form the pin side
# already accepts on `--repo=`. `i` is the index in `out` of the word before
# `w`, which the cluster arm needs — along with the parallel `typ` kinds and
# `cmdstart` marks that bound its lookback — and the other two do not.
function introducer_word(w, out, typ, cmdstart, wdepth, wgroup, gkind, cd, i) {
  return (w == "eval" || w ~ /^--command=?$/ \
    || shell_c_flag(w, out, typ, cmdstart, wdepth, wgroup, gkind, cd, i))
}

# A short-option cluster ending in `c` — `-c`, `-ec`, `-lc`, `-xc` —
# introduces a command line only when it is a shell's own flag. The letters
# may arrive in any order, since a shell's option parser does not care, so the
# cluster alone cannot tell `bash -xc` from `grep -Ec`. The command carrying
# the flag is what separates them: on another program the same cluster takes a
# pattern, and reading a pattern as a command line fails a correct file.
# The lookback reads that command's own words back to its start, each
# checked by names_shell, and any one of them naming a shell makes the
# cluster an introducer. Reading the whole command rather than only the flags
# ahead of the cluster is what reaches a shell an option argument or an
# operand stands in front of, as in `bash -o pipefail -c` and
# `docker run --entrypoint /bin/sh img -c`. The command's start is a word
# boundary, not the word list's, and it arrives two ways: a separator token,
# which the `typ` kind reports, and the punctuation that splits words without
# emitting a token, which `cmdstart` marks. Stopping at either is what keeps
# an earlier command's shell from vouching for a later cluster. A word is
# examined before the scan breaks on it, since the word a delimiter opens is
# itself command-initial and is where `$(bash -c …)` names its shell.
# A word nested inside a paren group belongs to that group's own command,
# not the one carrying the cluster, so the lookback steps over the whole
# group rather than reading through it — except a command substitution
# group standing as the very first word of the command being read, whose
# direct words the lookback does examine, since a command substitution
# there supplies the command word itself: `$(command -v bash) -c …` names
# its shell through the substitution's own output. A cluster the paren or
# backtick scan marked command-initial has no preceding word in its own
# command at all, so it is never an introducer on that basis alone.
function shell_c_flag(w, out, typ, cmdstart, wdepth, wgroup, gkind, cd, i,   lo, j, g) {
  if (w !~ /^-[[:alpha:]]*c$/) return 0
  # A cluster marked command-initial follows a subshell close or a code-span
  # backtick: no word precedes it in its own command, so nothing vouches.
  # The mark must belong to the depth being read here, not to some deeper
  # group that happened to close at this same word index — a nested
  # subshell's close (as inside `$((…))`) stamps a mark too, and it must
  # not be mistaken for one at the shallower depth this lookback is in.
  if (cmdstart[i + 1] == cd + 1) return 0
  for (; i >= 1 && typ[i] == "w"; i--) {
    if (wdepth[i] < cd) break
    if (wdepth[i] > cd) {
      # A nested group's words belong to a different command. Skip the
      # group as a unit rather than reading through it.
      lo = i
      while (lo > 1 && typ[lo - 1] == "w" && wdepth[lo - 1] > cd) lo--
      # A command substitution standing as the command's first word IS the
      # command word — its output becomes the program — so its direct
      # words are read. Later sibling groups are arguments; process
      # substitutions resolve to filenames; subshells are other commands.
      if (lo == 1 || typ[lo - 1] != "w" || wdepth[lo - 1] < cd) {
        g = 0
        for (j = lo; j <= i; j++) {
          if (wdepth[j] != cd + 1) continue
          if (g == 0) g = wgroup[j]
          if (wgroup[j] != g || gkind[g] != "s") break
          if (names_shell(out[j])) return 1
        }
      }
      i = lo
      continue
    }
    if (names_shell(out[i])) return 1
    if (cmdstart[i] == cd + 1) break
  }
  return 0
}

# Does `w`, stripped of structural punctuation and to its last path
# component, name a shell or a wrapper whose own -c takes a command line?
function names_shell(w) {
  w = strip_structural(w)
  sub(/^.*\//, "", w)
  return (w ~ /^(bash|sh|dash|ash|zsh|ksh|mksh|fish|su|runuser)$/)
}

# Trims YAML/JSON flow-syntax punctuation that can sit directly against an
# introducer with no space: a leading `[`, `{`, `(`, `,` opening a flow
# sequence or mapping entry, or a trailing `]`, `}`, `)`, `,`, `;` closing
# one. A leading `-` is never stripped — that would turn a `-c` flag into a
# bare `c` and hide it from introducer_word.
function strip_structural(w) {
  sub(/^[[{(,]+/, "", w)
  sub(/[]}),;]+$/, "", w)
  return w
}

# Does `nc` end the word a just-closed quote sits in? End-of-string and
# shell separators end it, and so does a structural closer from the
# enclosing YAML/JSON syntax — the same trailing punctuation
# strip_structural treats as structure, not word text. Anything else,
# including another quote or an ordinary character, means the word
# continues past the quote, so the payload inside is only a fragment of it.
function ends_word(nc) {
  return (nc == "" || nc == " " || nc == "\t" || nc == ";" || nc == "|" \
    || nc == "(" || nc == ")" || nc == "`" \
    || nc == "]" || nc == "}" || nc == "," || nc == "&")
}

# Queue a quoted payload for re-parsing as a command source. The queue is
# drained by the emit_records call whose tokenize pass filled it. `frag` is
# 1 when the word the payload came from continues past the closing quote —
# the payload is a fragment of a larger command line, not the whole
# argument, so a bare command triple in it is still an invocation rather
# than a mention. See the fragment lookahead in tokenize.
#
# `at_end` is 1 when the closing quote sits at the very end of the string
# being tokenized. That is what lets a fragment's own status reach a
# payload nested at its tail without also reaching one nested in its
# middle: a payload whose closing quote is followed by more of the
# enclosing text ended its own word cleanly and is a whole argument
# regardless of what encloses it. See the drain in emit_records.
#
# `kind` is the introducer kind from is_introducer's `intro_kind` ("eval"
# or empty) and `wordidx` is the position the payload's own word will
# occupy in the enclosing token list — `n + 1` at the moment the opening
# quote is reached, since exactly one word is still being built. Together
# they let the drain in emit_records tell whether a further word follows
# an eval payload in that list, which is what eval's own argument
# concatenation turns into part of the same command line.
function push_payload(p, frag, at_end, kind, wordidx) {
  payloads[++npay] = p
  payfrag[npay] = frag
  payend[npay] = at_end
  paykind[npay] = kind
  paywordidx[npay] = wordidx
}

# Split `s` into shell words. Fills out[1..n] with word text and
# typ[1..n] with the word kind:
#   w    ordinary word
#   sep  unquoted ; && || | & — a bare & only, never a redirection operator
#   cmt  unquoted # beginning a word; holds the rest of `s` and is last
# Returns n.
#
# `cmdstart` marks the word indices that begin a command without a separator
# token recording the boundary: the word after any opening paren and the word
# after a code-span backtick, always; on the close side, only a subshell's
# close marks — a substitution's result is a word in the enclosing command,
# not the start of a new one. Those delimiters split words but emit no token
# of their own, so the word kinds alone cannot tell a lookback where the
# command it is reading began. The stored value is the mark's depth plus one,
# with 0 read as unset, so a lookback at depth `cd` matches only a mark
# stamped at that same depth and is not misled by one a deeper, already-closed
# group left behind at the same word index. It is local because only the
# introducer lookback consults it, and only while this pass is running.
function tokenize(s, out, typ,   n, i, c, cur, has, L, last_unq, prev_unq, pay, intro, nc, frag, kind, wordidx, cmdstart, wdepth, wgroup, gkind, gstack, pdepth, gid, mark) {
  n = 0
  cur = ""
  has = 0
  i = 1
  L = length(s)
  last_unq = ""
  pdepth = 0
  gid = 0
  while (i <= L) {
    c = substr(s, i, 1)
    # Rebuilt every pass: only the two paths appending an ordinary unquoted
    # character set `last_unq`, so quoting, escaping, and every word
    # boundary leave it empty. Defaulting to empty is what keeps a quoted or
    # escaped `>` from reading as redirection syntax below.
    prev_unq = last_unq
    last_unq = ""
    if (c == " " || c == "\t") {
      if (has) { out[++n] = cur; typ[n] = "w"; wdepth[n] = pdepth; wgroup[n] = (pdepth > 0 ? gstack[pdepth] : 0); cur = ""; has = 0 }
      i++
      continue
    }
    if (c == "'") {
      # Single quotes: everything up to the next quote is literal. An
      # unterminated quote swallows the rest of the string as one word.
      intro = is_introducer(cur, n, out, typ, cmdstart, wdepth, wgroup, gkind, pdepth)
      kind = intro_kind
      wordidx = n + 1
      has = 1
      i++
      pay = ""
      while (i <= L && substr(s, i, 1) != "'") { pay = pay substr(s, i, 1); i++ }
      i++
      cur = cur pay
      # A payload is a fragment, not the whole word, when the word
      # continues past this closing quote — the next character is
      # anything but end-of-string or a boundary that ends a word.
      nc = (i <= L ? substr(s, i, 1) : "")
      frag = !ends_word(nc)
      if (intro) push_payload(pay, frag, (nc == ""), kind, wordidx)
      continue
    }
    if (c == "\"") {
      intro = is_introducer(cur, n, out, typ, cmdstart, wdepth, wgroup, gkind, pdepth)
      kind = intro_kind
      wordidx = n + 1
      has = 1
      i++
      pay = ""
      while (i <= L && substr(s, i, 1) != "\"") {
        if (substr(s, i, 1) == "\\" && i < L) i++
        pay = pay substr(s, i, 1)
        i++
      }
      i++
      cur = cur pay
      nc = (i <= L ? substr(s, i, 1) : "")
      frag = !ends_word(nc)
      if (intro) push_payload(pay, frag, (nc == ""), kind, wordidx)
      continue
    }
    if (c == "\\") {
      if (i < L) { i++; cur = cur substr(s, i, 1); has = 1 }
      i++
      continue
    }
    if (c == "(" || c == ")") {
      # Subshell and command-substitution punctuation. Delimiting words here
      # is what lets `$(gh attestation verify …)` match the command triple.
      # The kind decides what the lookback in shell_c_flag may read: a bare
      # `(` opens a new command, while `$(` and `<(`/`>(` produce a word in
      # the enclosing command. The tail of the pending word tells them
      # apart, and it is still in `cur` because the paren has not flushed
      # it yet.
      if (c == "(") {
        gkind[++gid] = (cur ~ /\$$/ ? "s" : (cur ~ /[<>]$/ ? "p" : "u"))
        # A bare `(` carries no sigil, so any pending word in front of it is
        # ordinary text of the command the subshell sits in and keeps that
        # command's depth. `$(`, `<(`, `>(` end in the sigil that spells the
        # substitution operator itself, so the word carrying it belongs to
        # the substitution, not the enclosing command's word list, and is
        # pushed to the new depth.
        if (gkind[gid] == "u") {
          if (has) { out[++n] = cur; typ[n] = "w"; wdepth[n] = pdepth; wgroup[n] = (pdepth > 0 ? gstack[pdepth] : 0); cur = ""; has = 0 }
          gstack[++pdepth] = gid
        } else {
          gstack[++pdepth] = gid
          if (has) { out[++n] = cur; typ[n] = "w"; wdepth[n] = pdepth; wgroup[n] = gid; cur = ""; has = 0 }
        }
        # The mark records the depth it applies to (offset by one so 0 still
        # reads as unset) — a mark set inside a nested group must not be
        # mistaken for one at the shallower depth an outer lookback reads.
        cmdstart[n + 1] = pdepth + 1
      } else {
        if (has) { out[++n] = cur; typ[n] = "w"; wdepth[n] = pdepth; wgroup[n] = (pdepth > 0 ? gstack[pdepth] : 0); cur = ""; has = 0 }
        # Only a subshell's close begins a new command; a substitution's
        # result is a word in the command that carries it. An unbalanced
        # close keeps the boundary. The kind is read before the pop, since
        # popping loses which group is closing; the mark itself is stamped
        # with the depth the close lands on, after the pop.
        mark = (pdepth == 0 || gkind[gstack[pdepth]] == "u")
        if (pdepth > 0) pdepth--
        if (mark) cmdstart[n + 1] = pdepth + 1
      }
      i++
      continue
    }
    if (c == "`") {
      # Legacy command substitution in shell, literal payload inside a
      # longer code span. Either way it delimits words rather than
      # joining them. A code span bounds commands on both sides, so no
      # depth change belongs here — see gkind for the substitution/subshell
      # distinction the paren arm tracks instead.
      if (has) { out[++n] = cur; typ[n] = "w"; wdepth[n] = pdepth; wgroup[n] = (pdepth > 0 ? gstack[pdepth] : 0); cur = ""; has = 0 }
      cmdstart[n + 1] = pdepth + 1
      i++
      continue
    }
    if (c == "#" && !has) {
      # A `#` only opens a comment at the start of a word.
      out[++n] = substr(s, i)
      typ[n] = "cmt"
      return n
    }
    if (c == "&" && substr(s, i, 2) != "&&" \
        && (prev_unq == ">" || substr(s, i + 1, 1) == ">")) {
      # A redirection operator, not a command separator: `2>&1`, `>&2`,
      # `2>&-`, `&>f`, `&>>f`. Ending the record at this `&` would truncate
      # it before a pin written after the redirection, reporting a correctly
      # pinned invocation as unpinned. Only an unquoted `>` makes the
      # following `&` redirection syntax — a quoted or escaped `>`, or a `>`
      # separated from this `&` by a word boundary or a removed code span,
      # is ordinary argument text, so `prev_unq` (the unquoted-append state
      # carried from the previous pass, not the raw last character of `cur`)
      # is what the left-hand check tracks. The `&&` exclusion keeps the
      # logical operator a separator even when a redirection precedes it.
      cur = cur c
      last_unq = c
      has = 1
      i++
      continue
    }
    if (c == ";" || c == "&" || c == "|") {
      if (has) { out[++n] = cur; typ[n] = "w"; wdepth[n] = pdepth; wgroup[n] = (pdepth > 0 ? gstack[pdepth] : 0); cur = ""; has = 0 }
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
    last_unq = c
    i++
  }
  if (has) { out[++n] = cur; typ[n] = "w"; wdepth[n] = pdepth; wgroup[n] = (pdepth > 0 ? gstack[pdepth] : 0) }
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
#
# `in_fragment` is 1 when `s` itself is only a fragment of the word that
# carried it — the caller's own quoted region ended mid-word. Every
# payload drained from a fragment is a fragment too, however whole its own
# closing quote looks, because it can only ever be part of what its
# parent was part of. Top-level callers (scan_spans, flush_runnable) are
# never fragments, so they pass 0.
function emit_records(s, mention_ok, in_fragment,   out, typ, n, i, j, extra, rec, pinned, base, k, cnt, mine, minefrag, forced) {
  base = npay
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
      # A second command triple starts a new record. Parens delimit words
      # without emitting a token, so without this an invocation inside one
      # substitution would absorb the next one and lend it its pin.
      if (j + 2 <= n && out[j] == "gh" \
          && typ[j + 1] == "w" && out[j + 1] == "attestation" \
          && typ[j + 2] == "w" && out[j + 2] == "verify") break
      rec = rec " " out[j]
      extra++
      if (out[j] == "--repo=" slug || out[j] == "-R=" slug || out[j] == "-R" slug) pinned = 1
      else if ((out[j] == "--repo" || out[j] == "-R") && j < n && typ[j + 1] == "w" && out[j + 1] == slug) pinned = 1
    }
    # Resume scanning at the token that ended this record, so a chained
    # command is judged on its own arguments.
    i = j - 1
    if (mention_ok && extra == 0) continue
    print (pinned ? "ok" : "bad") "\t" rec
  }
  # Payloads this call's tokenize pass captured, re-parsed as command sources.
  # Copying them out before recursing keeps each level draining only its own,
  # and preserves the order they appeared in. Every payload is shorter than
  # the string that carried it, so the recursion terminates.
  #
  # A payload is in fragment context when its own quoted region ended
  # mid-word (payfrag), or when it sits at the very end of a string that is
  # itself a fragment (in_fragment && payend). The second case is what
  # carries fragment status down to a payload nested at a fragment's tail
  # without also reaching one nested in its middle: a payload whose closing
  # quote is followed by more of the enclosing text ended its own word
  # cleanly and is a whole argument regardless of what encloses it. A
  # payload holding only the command triple is a mention unless it is in
  # fragment context, where a bare triple is read as an invocation rather
  # than a mention. See push_payload.
  #
  # An `eval` payload is also forced into invocation context when a
  # further word of this level's own token list follows the word its quote
  # closed into (checked here, against `typ`, now that this level's own
  # tokenize call has filled it): `eval` concatenates its arguments into
  # one command line, so a bare triple quoted alone still runs whatever
  # word comes after it, unlike `-c`/`--command`, where a following word is
  # a separate argument to the invoked shell rather than more of the
  # command. A following separator token does not concatenate and leaves
  # the payload a mention.
  cnt = 0
  for (k = base + 1; k <= npay; k++) {
    mine[++cnt] = payloads[k]
    forced = (paykind[k] == "eval" && paywordidx[k] + 1 <= n && typ[paywordidx[k] + 1] == "w")
    minefrag[cnt] = (payfrag[k] || (in_fragment && payend[k]) || forced)
  }
  npay = base
  for (k = 1; k <= cnt; k++) emit_records(mine[k], (minefrag[k] ? 0 : 1), minefrag[k])
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
      emit_records(carry_text, 1, 0)
      carry_open = 0
      carry_text = ""
      # A span delimits words rather than joining them, matching how a
      # backtick behaves when it reaches the splitter directly. Without the
      # separator the text on either side of a removed span glues into one
      # word, which can fuse a redirection onto a following separator.
      strip_line = strip_line " "
    } else {
      carry_text = carry_text substr(s, i, run)
    }
    i += run
  }
  # A span still open at end of line continues onto the next one; the
  # newline joins as a space. On a runnable line the span cannot be
  # allowed to keep absorbing: an unterminated backtick would swallow
  # every following line into text that is later discarded. Return what
  # it captured to this line's runnable text instead.
  if (carry_open > 0) {
    if (runnable) {
      strip_line = strip_line " " carry_text
      carry_open = 0
      carry_text = ""
    } else {
      carry_text = carry_text " "
    }
  }
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
  fence_lang = normalize_info(info)
  fence_runnable = lang_runnable(fence_lang)
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
    emit_records(joined, 0, 0)
  }
  nrun = 0
}

# A leading `#` makes the line a comment wherever the line is shell source:
# a script, a workflow, a fenced shell block, an indented code block. The
# test must precede the span scan — a comment can carry a backticked command
# with an elided argument, which the span rule would otherwise read as an
# invocation, blocking documentation that merely describes the command.
#
# The cost is that an invocation shown after a root `#` prompt is not
# inspected. Nothing in the line distinguishes a root prompt from prose, and
# the miss is preferred to a false positive: a false positive blocks a
# correct commit, while this gap affects only a shape no tracked doc uses.
function is_comment(line) {
  return (line ~ /^[[:space:]]*#/)
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
      if (is_comment($0)) next
      scan_spans($0, 1)
      push_runnable(strip_line)
      next
    }
    if (is_fence_open($0)) next
    # An indented code block. The repo has none today, and only a line
    # carrying the command outside a span can produce a record, so the
    # simple rule costs nothing that CommonMark container tracking buys.
    if ($0 ~ /^(    |\t)/) {
      if (is_comment($0)) next
      scan_spans($0, 1)
      push_runnable(strip_line)
      next
    }
    # Prose. A `#` here opens a heading, not a comment, so prose keeps its
    # own treatment: an inline code span is the only runnable shape.
    scan_spans($0, 0)
    next
  }

  if (is_comment($0)) next
  scan_spans($0, 1)
  push_runnable(strip_line)
}

END {
  kill_carry()
  flush_runnable()
}
