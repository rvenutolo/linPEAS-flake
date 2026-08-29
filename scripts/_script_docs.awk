# scripts/_script_docs.awk
#
# Read one bash script on stdin; emit JSON describing its shdoc-style
# annotations. Recognized tags: @description, @arg, @option, @example,
# @exitcode, @stdout, and the non-rendering @generates /
# @generates-block declarations. Several tags may share one comment line
# when separated by two or more spaces (`# @arg $1 a  @arg $2 b`).
#
# Default scope reads the file header only — the contiguous comment run
# before the first blank or non-comment line — so a function-body
# `@description` is ignored. `-v scope=library` additionally reads every column-0
# `# @description` block that follows the header and binds it to the
# `function name()` / `name()` line it precedes, emitting one entry per
# function under `functions`. A function with no preceding block is a
# contract gap: exit 2. A block followed by anything other than a
# function line is discarded with a warning.
#
# Exit 2 if the header @description is absent.

BEGIN {
  in_header = 1
  # Target 0 is the file header; targets 1..n_fn are functions. Every
  # per-target field is keyed by target so one tag handler serves both.
  cur = 0
  n_fn = 0
  pending = 0
  fatal = 0
  state = ""  # "desc" | "example" | ""
  init_target(0)
}

function init_target(t) {
  have_desc[t] = 0
  desc[t] = ""
  n_args[t] = 0
  n_opts[t] = 0
  n_exit[t] = 0
  n_std[t] = 0
  example[t] = ""
  fname[t] = ""
}

# Header terminator: first non-comment line (a blank line ends it below).
in_header && !/^[[:space:]]*$/ && !/^#/ {
  in_header = 0
  # The terminator line itself may be a function line in library scope,
  # so it falls through to the body rules below rather than being consumed.
}

# Everything past the header is invisible in default scope.
!in_header && scope != "library" { next }

# Blank line: closes any open multi-line capture and ends the header.
# The header is one contiguous comment run: a second `@description`
# block after a blank line belongs to a function, not to the file, and
# must not overwrite the header even when no code line separates them.
/^[[:space:]]*$/ {
  state = ""
  in_header = 0
  next
}

# A shellcheck directive is tooling, not prose: it neither continues a
# description nor starts a block.
/^#[[:space:]]+shellcheck[[:space:]]/ {
  state = ""
  next
}

# Tag line: `# @<tag> ...`, possibly several tags per line.
/^#[[:space:]]+@[A-Za-z]+/ {
  line = $0
  sub(/^#[[:space:]]+/, "", line)
  if (!in_header) {
    if (line ~ /^@description([[:space:]]|$)/) {
      # A new function block starts here; an earlier block that never
      # reached a function line is dropped in favour of this one.
      if (pending) {
        print "warning: @description block not followed by a function (discarded)" > "/dev/stderr"
      } else {
        n_fn++
      }
      cur = n_fn
      init_target(cur)
      pending = 1
    } else if (!pending) {
      print "warning: @" tag_name(line) " outside a @description block (ignored)" > "/dev/stderr"
      next
    }
  }
  n_seg = split(line, seg, /[[:space:]][[:space:]]+@/)
  for (s = 1; s <= n_seg; s++) {
    handle_tag(s == 1 ? seg[s] : "@" seg[s])
  }
  next
}

# Continuation / body lines of a comment run.
/^#/ {
  if (!in_header && !pending) { next }
  line = $0
  body = line
  sub(/^#[[:space:]]?/, "", body)
  if (state == "desc") {
    desc[cur] = desc[cur] "\n" body
  } else if (state == "example") {
    if (example[cur] == "") {
      example[cur] = body
    } else {
      example[cur] = example[cur] "\n" body
    }
  }
  # Otherwise (state == ""): plain comment we do not capture.
  next
}

# Library scope, non-comment line: a function line binds the pending
# block; any other code line orphans it.
{
  state = ""
  name = function_name($0)
  if (name != "") {
    if (!pending) {
      print "function " name " has no @description" > "/dev/stderr"
      # `exit` inside a rule still runs END; the flag keeps END from
      # printing a document for a file whose contract is incomplete.
      fatal = 1
      exit 2
    }
    fname[cur] = name
    pending = 0
    cur = 0
    next
  }
  if (pending) {
    print "warning: @description block not followed by a function (discarded)" > "/dev/stderr"
    n_fn--
    pending = 0
    cur = 0
  }
  next
}

# Name of the function a line defines, or "" for any other line.
function function_name(l,   n) {
  if (l ~ /^function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/) {
    n = l
    sub(/^function[[:space:]]+/, "", n)
    sub(/[[:space:]]*\(\).*$/, "", n)
    return n
  }
  if (l ~ /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/) {
    n = l
    sub(/[[:space:]]*\(\).*$/, "", n)
    return n
  }
  return ""
}

function tag_name(l,   t) {
  t = l
  sub(/^@/, "", t)
  sub(/[[:space:]].*$/, "", t)
  return t
}

# One `@tag rest` segment, applied to the current target.
function handle_tag(segment,   tag, rest, name, text) {
  tag = tag_name(segment)
  rest = segment
  sub(/^@[A-Za-z]+[[:space:]]*/, "", rest)

  if (tag == "description") {
    desc[cur] = rest
    have_desc[cur] = 1
    state = "desc"
  } else if (tag == "arg") {
    # rest = "$N TEXT..."
    name = rest
    sub(/[[:space:]].*$/, "", name)
    text = rest
    sub(/^[^[:space:]]+[[:space:]]*/, "", text)
    arg_name[cur, n_args[cur]] = name
    arg_text[cur, n_args[cur]] = text
    n_args[cur]++
    state = ""
  } else if (tag == "option") {
    name = rest
    sub(/[[:space:]].*$/, "", name)
    text = rest
    sub(/^[^[:space:]]+[[:space:]]*/, "", text)
    opt_flag[cur, n_opts[cur]] = name
    opt_text[cur, n_opts[cur]] = text
    n_opts[cur]++
    state = ""
  } else if (tag == "exitcode") {
    # rest = "N TEXT..."
    name = rest
    sub(/[[:space:]].*$/, "", name)
    text = rest
    sub(/^[^[:space:]]+[[:space:]]*/, "", text)
    exit_code[cur, n_exit[cur]] = name
    exit_text[cur, n_exit[cur]] = text
    n_exit[cur]++
    state = ""
  } else if (tag == "stdout") {
    std_text[cur, n_std[cur]] = rest
    n_std[cur]++
    state = ""
  } else if (tag == "example") {
    state = "example"
    # rest (if any) ignored; example body is the following indented lines
  } else if (tag == "generates" || tag == "generates-block") {
    # Declared for scripts/check-size-label-ignores.sh, which reads these
    # tags straight from the script source. They carry no rendered output,
    # so they are recognized and dropped rather than reported unknown —
    # a tag this repo requires must not also be one this parser warns about.
    state = ""
  } else {
    print "warning: unknown tag @" tag > "/dev/stderr"
    state = ""
  }
}

END {
  if (fatal) { exit 2 }
  if (!have_desc[0]) {
    print "missing @description" > "/dev/stderr"
    exit 2
  }
  if (pending) {
    print "warning: @description block not followed by a function (discarded)" > "/dev/stderr"
    n_fn--
  }
  printf "{"
  print_body(0)
  printf ",\"functions\":["
  for (f = 1; f <= n_fn; f++) {
    if (f > 1) printf ","
    printf "{\"name\":\"%s\",", json_escape(fname[f])
    print_body(f)
    printf "}"
  }
  printf "]"
  printf "}\n"
}

# The fields shared by the header and by every function entry.
function print_body(t,   i) {
  printf "\"description\":\"%s\"", json_escape(desc[t])
  printf ",\"args\":["
  for (i = 0; i < n_args[t]; i++) {
    if (i > 0) printf ","
    printf "{\"name\":\"%s\",\"text\":\"%s\"}", \
      json_escape(arg_name[t, i]), json_escape(arg_text[t, i])
  }
  printf "]"
  printf ",\"options\":["
  for (i = 0; i < n_opts[t]; i++) {
    if (i > 0) printf ","
    printf "{\"flag\":\"%s\",\"text\":\"%s\"}", \
      json_escape(opt_flag[t, i]), json_escape(opt_text[t, i])
  }
  printf "]"
  printf ",\"exitcodes\":["
  for (i = 0; i < n_exit[t]; i++) {
    if (i > 0) printf ","
    printf "{\"code\":\"%s\",\"text\":\"%s\"}", \
      json_escape(exit_code[t, i]), json_escape(exit_text[t, i])
  }
  printf "]"
  printf ",\"stdout\":["
  for (i = 0; i < n_std[t]; i++) {
    if (i > 0) printf ","
    printf "\"%s\"", json_escape(std_text[t, i])
  }
  printf "]"
  printf ",\"example\":\"%s\"", json_escape(example[t])
}

function json_escape(s,   out) {
  out = s
  gsub(/\\/, "\\\\", out)
  gsub(/"/, "\\\"", out)
  gsub(/\n/, "\\n", out)
  gsub(/\r/, "\\r", out)
  gsub(/\t/, "\\t", out)
  return out
}
