# scripts/lib/secret-uses.sh
#
# @description Read the uses of the GitHub Actions `secrets` context in
# workflow text, one line at a time: each secret a `${{ }}` expression
# names, each expression that uses the context without a literal name,
# and each `${{` not closed on its line; and the decoded text of a YAML
# file's double-quoted scalars, which a reader of the file text misses;
# and the jobs that hand every secret on with `secrets: inherit`.
# Source after `set -Eeuo pipefail` and after scripts/lib/ascii-match.sh,
# and after scripts/lib/job-keys.sh for `inherit_secret_jobs`.
# shellcheck shell=bash

# A secret reference in the dot or the index form, with any name, the
# context's ASCII letters in either case, as a grep -E regex.
SECRET_NAMED_REF_RE="$(secret_ref_regex '[A-Za-z0-9_]+')"
readonly SECRET_NAMED_REF_RE
# Any use of the context: a reference with a literal name, or the
# context's name and the one character after it, which must not continue
# the name. grep takes the longest match, so a reference with a name is
# taken whole. A use whose character after it is the bound before a
# second use hides that second use, but the first is a finding already.
# The one character before a use must not continue a name or a path:
# `secrets` as a step id (`steps.secrets.outputs.x`) or an input is no
# use of the context. A match therefore starts with that character, which
# the reader drops.
SECRET_USE_RE="[^A-Za-z0-9_.-](${SECRET_NAMED_REF_RE}|$(ascii_fold_regex secrets)[^A-Za-z0-9_-])"
readonly SECRET_USE_RE
# One `${{ }}` expression on a line. A `}}` may sit inside a run of text
# between single quotes, as in a format string's escaped brace, and a
# quote may also stand alone; grep takes the longest match, so the span
# runs to the last `}}` it can reach that way. That reaches past a `}}`
# in a literal whether its quotes are written once or, in a YAML
# single-quoted scalar, twice. Text between two expressions on a line is
# read too when quotes on either side pair across it.
readonly SECRET_EXPRESSION_RE="\\\$\\{\\{([^}]|\\}[^}]|'[^']*')*\\}\\}"
# A `${{` with no `}}` after it on its line, which SECRET_EXPRESSION_RE
# cannot reach: grep takes the longer match where both can start.
readonly SECRET_EXPRESSION_OR_OPEN_RE="(${SECRET_EXPRESSION_RE})|\\\$\\{\\{"

# @description Print one record per use of the `secrets` context in the
# text on stdin (a workflow file or a part of one), as
# `LINE<TAB>KIND<TAB>TEXT`, in the order of the text. Text outside `${{ }}`
# is not read. The kinds:
# - `named`: a reference with a literal name, in the dot or the
#   single-quoted index form; TEXT is the reference.
# - `unnamed`: an expression that uses the context in any other way, so no
#   name in the text says which secret it reads: the whole context
#   (`toJSON(secrets)`), a name the expression computes
#   (`secrets[format(...)]`, `secrets[env.NAME]`), the object filter
#   (`secrets.*`), a double-quoted index, or the word `secrets` inside a
#   string literal, which this reader cannot tell from a use. One record per
#   expression, after its `named` records; TEXT is the expression.
# - `open`: a `${{` not closed on its line; TEXT is `${{`. GitHub Actions
#   reads an expression broken across the lines of a block scalar, and
#   this reader reads one line at a time, so whatever the expression reads
#   is unknown.
# @stdout the records
# @exitcode 0 the text was read, whether it holds a use or not
# @exitcode 2 grep failed reading it
function secret_uses() {
  local expressions rc=0
  expressions="$(LC_ALL=C grep --extended-regexp --line-number --only-matching \
    -- "${SECRET_EXPRESSION_OR_OPEN_RE}")" || rc=$?
  if ((rc > 1)); then
    return 2
  fi
  local line lineno rest tokens token unnamed
  while IFS= read -r line; do
    [[ -z ${line} ]] && continue
    lineno="${line%%:*}"
    rest="${line#*:}"
    # shellcheck disable=SC2016 # the expression opener is literal text
    if [[ ${rest} == '${{' ]]; then
      printf '%s\topen\t%s\n' "${lineno}" "${rest}"
      continue
    fi
    rc=0
    tokens="$(LC_ALL=C grep --extended-regexp --only-matching \
      -- "${SECRET_USE_RE}" <<<"${rest}")" || rc=$?
    if ((rc > 1)); then
      return 2
    fi
    unnamed=0
    while IFS= read -r token; do
      [[ -z ${token} ]] && continue
      token="${token:1}"
      if ascii_match "${token}" "^${SECRET_NAMED_REF_RE}\$"; then
        printf '%s\tnamed\t%s\n' "${lineno}" "${token}"
      else
        unnamed=1
      fi
    done <<<"${tokens}"
    if ((unnamed)); then
      printf '%s\tunnamed\t%s\n' "${lineno}" "${rest}"
    fi
  done <<<"${expressions}"
}

# @description Print the text of each double-quoted scalar in a YAML file
# as `yq` decodes it, keys and values alike, each on its own lines. GitHub
# Actions evaluates an expression in the decoded text, and a double-quoted
# scalar is the one YAML style whose escapes (`\x65`, `\u0065`, `\n`, an
# escaped line break) make that text differ from the file's: an escape can
# hide a use's name, its `${{` or its `}}` from a reader of the file text.
# A tagged scalar is printed too, whatever its style: `yq` reports the
# style of a tagged scalar as `tagged` or `<unknown>`, never `double`, so
# every scalar is printed but an untagged plain, single-quoted, literal or
# folded one, the styles that hold no escape. A NUL is printed as a space, since grep reads text holding a NUL as
# binary and prints no match, and a NUL continues no name. A scalar written
# once under an anchor is printed once, however many aliases repeat it.
# @arg $1 workflow file path
# @stdout the decoded texts
# @exitcode 0 the file was read, whether it holds such a scalar or not
# @exitcode 2 `yq` could not read the file
function double_quoted_scalars() {
  local -r file="$1"
  local texts
  local -r escapable='select(kind == "scalar" and style != "" and style != "single" and style != "literal" and style != "folded")'
  if ! texts="$(yq eval "(.. | ${escapable}), (.. | select(kind == \"map\") | keys | .[] | ${escapable})" "${file}" | tr '\000' ' ')"; then
    return 2
  fi
  if [[ -n ${texts} ]]; then
    printf '%s\n' "${texts}"
  fi
}

# A job's `secrets:` value read as `inherit`, as a `yq` condition on that
# node: anything but a map or null (see inherit_secret_jobs).
readonly INHERITS_SECRETS='(kind == "scalar" and tag != "!!null") or kind == "seq"'

# @description Print, one per line as a JSON string, the key of each job
# that hands every secret to the reusable workflow it calls: its
# `secrets:` is `inherit`, which no `${{ }}` holds, so `secret_uses` never
# reads it. GitHub Actions takes a map or `inherit` there and nothing else,
# so any value but a map or null is read as `inherit` without its text
# being compared. The `jobs:` node and each job are read through their
# aliases and merge keys, and a merge key directly under `jobs:` brings its
# jobs in. An explicit `secrets:` map names what it hands on in its values,
# which `secret_uses` reads, so its job is not printed. Source
# scripts/lib/job-keys.sh before this file.
# @arg $1 workflow file path
# @stdout the job keys
# @exitcode 0 the file was read, whether a job inherits or not
# @exitcode 2 `yq` could not read the file
function inherit_secret_jobs() {
  local -r file="$1"
  local keys
  if ! keys="$(yq eval "${YQ_MERGE_SPEC[@]}" "[${JOBS_NODE}"' | explode(.) | select(kind == "map") | to_entries[] | select(.value | explode(.) | select(kind == "map") | .secrets | '"${INHERITS_SECRETS}"') | .key | tostring | to_json(0)] | .[]' "${file}")"; then
    return 2
  fi
  if [[ -n ${keys} ]]; then
    printf '%s\n' "${keys}"
  fi
}
