# scripts/_script_docs.awk
#
# Read one bash script on stdin; emit JSON describing its shdoc-style
# header annotations. Stops at the first non-comment, non-blank line
# so that function-body `@description` annotations are ignored.
# Recognized tags: @description, @arg, @option, @example.
# Exit 2 if @description is absent.

BEGIN {
  in_header = 1
  have_desc = 0
  description = ""
  n_args = 0
  n_options = 0
  example = ""
  state = ""  # "desc" | "example" | ""
}

# Header terminator: first line that is neither a comment nor blank.
in_header && !/^[[:space:]]*$/ && !/^#/ {
  in_header = 0
}

!in_header { next }

# Blank line inside header: closes any open multi-line capture.
in_header && /^[[:space:]]*$/ {
  state = ""
  next
}

# Tag line: `# @<tag> ...`
in_header && /^#[[:space:]]+@[A-Za-z]+/ {
  line = $0
  # Strip leading "# " (one or more spaces).
  sub(/^#[[:space:]]+/, "", line)
  # Extract tag (token after @, before first space).
  tag = line
  sub(/^@/, "", tag)
  rest = tag
  sub(/^[A-Za-z]+[[:space:]]*/, "", rest)  # rest of the line after the tag
  sub(/[[:space:]].*$/, "", tag)            # tag name alone

  if (tag == "description") {
    description = rest
    have_desc = 1
    state = "desc"
  } else if (tag == "arg") {
    # rest = "$N TEXT..."
    name = rest
    sub(/[[:space:]].*$/, "", name)
    text = rest
    sub(/^[^[:space:]]+[[:space:]]*/, "", text)
    arg_name[n_args] = name
    arg_text[n_args] = text
    n_args++
    state = ""
  } else if (tag == "option") {
    flag = rest
    sub(/[[:space:]].*$/, "", flag)
    text = rest
    sub(/^[^[:space:]]+[[:space:]]*/, "", text)
    opt_flag[n_options] = flag
    opt_text[n_options] = text
    n_options++
    state = ""
  } else if (tag == "example") {
    state = "example"
    # rest (if any) ignored; example body is the following indented lines
  } else {
    print "warning: unknown tag @" tag > "/dev/stderr"
    state = ""
  }
  next
}

# Continuation / body lines inside header.
in_header && /^#/ {
  line = $0
  if (state == "desc") {
    # Continuation: "# <text>" (single space) appended with \n.
    body = line
    sub(/^#[[:space:]]?/, "", body)
    description = description "\n" body
  } else if (state == "example") {
    # Capture example body: "#  ..." or "# ..." — preserve trailing content.
    body = line
    sub(/^#[[:space:]]?/, "", body)
    if (example == "") {
      example = body
    } else {
      example = example "\n" body
    }
  }
  # Otherwise (state == ""): plain header comment we don't capture.
  next
}

END {
  if (!have_desc) {
    print "missing @description" > "/dev/stderr"
    exit 2
  }
  printf "{"
  printf "\"description\":\"%s\"", json_escape(description)
  printf ",\"args\":["
  for (i = 0; i < n_args; i++) {
    if (i > 0) printf ","
    printf "{\"name\":\"%s\",\"text\":\"%s\"}", \
      json_escape(arg_name[i]), json_escape(arg_text[i])
  }
  printf "]"
  printf ",\"options\":["
  for (i = 0; i < n_options; i++) {
    if (i > 0) printf ","
    printf "{\"flag\":\"%s\",\"text\":\"%s\"}", \
      json_escape(opt_flag[i]), json_escape(opt_text[i])
  }
  printf "]"
  printf ",\"example\":\"%s\"", json_escape(example)
  printf "}\n"
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
