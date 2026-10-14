#!/usr/bin/env bash
# scripts/check-pr-workflows-no-secrets.sh
#
# @description Lint: no workflow triggered by `pull_request` /
# `pull_request_target` references any `secrets.*` other than
# `secrets.GITHUB_TOKEN`.

# Verify that no workflow triggered by `pull_request` or
# `pull_request_target` references any `secrets.*` other than
# `secrets.GITHUB_TOKEN`. PR-authored code executes in the runner with
# whatever secrets are exposed via env; restricting to GITHUB_TOKEN
# (read-only on fork PRs by default) prevents accidental secret exposure
# if a future maintainer wires a non-GITHUB_TOKEN secret into a
# PR-triggered workflow's env.
#
# GitHub Actions reads a secret's name whatever its case, so a reference
# is read with the ASCII letters of `secrets` and of the name in either
# case: `SECRETS.FOO` is refused, and `secrets.github_token` is the
# GITHUB_TOKEN and allowed. It reads the index form as the dot form:
# `secrets['FOO']` is refused too. A reference is read wherever it sits
# inside a `${{ }}` expression on one line, beside an operator or as a
# function argument as well as alone, and past a `}}` inside a string
# literal. Any other use of the `secrets` context in an expression is
# refused, since no name in the text says which secret it reads: the
# whole context (`toJSON(secrets)`), a name the expression computes
# (`secrets[format(...)]`, `secrets[env.NAME]`), the object filter
# (`secrets.*`), and a double-quoted index. So is the word `secrets`
# inside a string literal of an expression, which the guard cannot tell
# from a use. A `${{` not closed on its own line is refused as well: GitHub
# Actions reads an expression broken across the lines of a block scalar,
# and the guard reads one line at a time. Not read: text outside `${{ }}`.
#
# Honors WORKFLOWS_DIR_OVERRIDE (defaults to .github/workflows) so the
# test harness can point at a temp dir with a single fixture.
#
# Exits 0 if every PR-triggered workflow is clean, 1 on a secrets
# violation or an expression it refuses, 2 on a tooling error (workflows
# dir missing, yq missing, or a workflow yq cannot parse).
set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"
# shellcheck source=scripts/lib/ascii-match.sh
source "${_lib_dir}/lib/ascii-match.sh"

# A secret reference in the dot or the index form, with any name, the
# context's ASCII letters in either case, as a grep -E regex.
NAMED_REF_RE="$(secret_ref_regex '[A-Za-z0-9_]+')"
readonly NAMED_REF_RE
# Any use of the context: a reference with a literal name, or the
# context's name and the one character after it, which must not continue
# the name. grep takes the longest match, so a reference with a name is
# taken whole. A use whose character after it is the bound before a
# second use hides that second use, but the first is a finding already.
# The one character before a use must not continue a name or a path:
# `secrets` as a step id (`steps.secrets.outputs.x`) or an input is no
# use of the context. A match therefore starts with that character, which
# the reader drops.
SECRET_USE_RE="[^A-Za-z0-9_.-](${NAMED_REF_RE}|$(ascii_fold_regex secrets)[^A-Za-z0-9_-])"
readonly SECRET_USE_RE
# One `${{ }}` expression on a line. A `}}` may sit inside a run of text
# between single quotes, as in a format string's escaped brace, and a
# quote may also stand alone; grep takes the longest match, so the span
# runs to the last `}}` it can reach that way. That reaches past a `}}`
# in a literal whether its quotes are written once or, in a YAML
# single-quoted scalar, twice. Text between two expressions on a line is
# read too when quotes on either side pair across it.
readonly EXPRESSION_RE="\\\$\\{\\{([^}]|\\}[^}]|'[^']*')*\\}\\}"
# A `${{` with no `}}` after it on its line, which EXPRESSION_RE cannot
# reach: grep takes the longer match where both can start.
readonly EXPRESSION_OR_OPEN_RE="(${EXPRESSION_RE})|\\\$\\{\\{"

readonly WORKFLOWS_DIR="${WORKFLOWS_DIR_OVERRIDE:-.github/workflows}"

if [[ ! -d ${WORKFLOWS_DIR} ]]; then
  printf 'pr-workflows-no-secrets lint: workflows dir %s missing\n' "${WORKFLOWS_DIR}" >&2
  exit 2
fi

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 2
fi

# The `on:` node every read starts from, with its aliases resolved. It
# is the one root key that is `on` or an alias of `on`: a root holding
# more than one makes `yq` fail ("on: is given more than once"). With no
# such key it is `.on`, which is how an `on:` a root merge key brings in
# is read, since the merged keys are not the root's own. Reading `.on`
# also makes a root that is a list fail the read; a scalar root fails
# when its keys are listed.
# `explode`, handed that node alone, resolves one level of aliases per
# pass: the aliases a node holds, not those inside what they stand for.
# So the node goes through sixteen passes, and one that still holds an
# alias after them is refused by `yq` with an error rather than read. A
# file `yq` reads through this is never passed with an alias left in it.
# Its memory cost is a stated limit: docs/development/linting.md, section
# "YAML aliases in workflow reads".
# shellcheck disable=SC2016 # yq program literal; its $ names are yq variables
readonly ON_NODE='.on as $plain | [to_entries[] | select((.key | explode(.)) == "on") | .value] as $all | with(select($all | length > 1); error("on: is given more than once")) | ($all + [$plain] | .[0]) as $n | [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16][] as $i ireduce ($n; explode(.)) | with(select([... | select(kind == "alias")] | length > 0); error("on: holds an alias nested too deep to resolve"))'

# @description Return 0 if the workflow file is triggered by pull_request
# or pull_request_target; 1 otherwise. Handles every `on:` shape yq can
# parse: scalar, flow/block sequence, and flow/block map (quoted or
# comment-trailing keys included), whatever tag the node carries. The
# read starts from ON_NODE above, so a trigger written through an anchor
# or brought in by a merge key puts the workflow in scope, and a merge
# key `yq` cannot resolve elsewhere in the file does not fail the read.
# Exits 2 on a workflow yq cannot parse, and on one ON_NODE refuses (a
# root key resolving to `on` given twice, or an `on:` still holding an
# alias after its passes) — fail closed, never skip-scan.
# @arg $1 path to workflow YAML
function is_pr_triggered() {
  local -r file="$1"
  local triggers
  # Capture yq's output (and exit status) into a variable rather than
  # feeding a loop or pipe from a process substitution: a procsub's exit
  # status is not propagated under set -Eeuo pipefail, so a yq parse
  # failure would silently exempt the file from scanning.
  #
  # mikefarah/yq does not lex `if $t == ... then ... else ... end`
  # (tested empirically: bare `if true then 1 else 2 end` fails with a
  # lexer error), so trigger-shape branching is done via three
  # alternatives, each selecting on the node's kind, unioned by the comma
  # operator instead of a single conditional.
  if ! triggers="$(yq eval "${ON_NODE}"' | ((select(kind == "scalar")), (select(kind == "seq") | .[]), (select(kind == "map") | keys | .[]))' "${file}")"; then
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${file}" >&2
    exit 2
  fi
  grep --extended-regexp --line-regexp --quiet 'pull_request|pull_request_target' <<<"${triggers}"
}

# @description Scan a PR-triggered workflow for disallowed secrets uses
# and for expressions not closed on their line. Increments the global
# failed counter and prints violations to stderr.
# @arg $1 path to workflow YAML
function scan_secrets() {
  local -r file="$1"
  local tmp
  tmp="$(make_temp)"
  LC_ALL=C grep --extended-regexp --line-number --only-matching \
    "${EXPRESSION_OR_OPEN_RE}" "${file}" >"${tmp}" || true

  local line
  while IFS= read -r line; do
    [[ -z ${line} ]] && continue
    local lineno="${line%%:*}"
    local rest="${line#*:}"
    # shellcheck disable=SC2016 # the expression opener is literal text
    if [[ ${rest} == '${{' ]]; then
      printf '%s:%s: expression not closed on its line, not allowed in PR-triggered workflow\n' \
        "${file}" "${lineno}" >&2
      failed=$((failed + 1))
      continue
    fi
    local tokens_file
    tokens_file="$(make_temp)"
    LC_ALL=C grep --extended-regexp --only-matching \
      "${SECRET_USE_RE}" >"${tokens_file}" <<<"${rest}" || true
    local token unnamed=0
    while IFS= read -r token; do
      [[ -z ${token} ]] && continue
      token="${token:1}"
      if ! ascii_match "${token}" "^${NAMED_REF_RE}\$"; then
        unnamed=1
        continue
      fi
      # Under LC_ALL=C the token holds ASCII only, so upper-casing its
      # name folds nothing else.
      local name
      name="$(secret_ref_name "${token}")"
      if [[ ${name^^} == 'GITHUB_TOKEN' ]]; then
        allowed=$((allowed + 1))
        continue
      fi
      printf '%s:%s: %s not allowed in PR-triggered workflow\n' \
        "${file}" "${lineno}" "${token}" >&2
      failed=$((failed + 1))
    done <"${tokens_file}"
    rm --force -- "${tokens_file}"
    if ((unnamed)); then
      printf '%s:%s: %s reads the secrets context without a literal name, not allowed in PR-triggered workflow\n' \
        "${file}" "${lineno}" "${rest}" >&2
      failed=$((failed + 1))
    fi
  done <"${tmp}"
  rm --force -- "${tmp}"
}

failed=0
# Scope tallies behind the clean-path summary. Most of this directory is
# out of scope by design, so a pass has to say how much of it the rule
# was actually applied to.
examined=0
scanned=0
skipped=0
allowed=0
shopt -s nullglob
declare -a workflow_files=()
glob_into workflow_files 'workflow YAML' \
  "${WORKFLOWS_DIR}/*.yml" "${WORKFLOWS_DIR}/*.yaml"
for wf in "${workflow_files[@]}"; do
  examined=$((examined + 1))
  if is_pr_triggered "${wf}"; then
    scanned=$((scanned + 1))
    scan_secrets "${wf}"
  else
    skipped=$((skipped + 1))
  fi
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d violation(s) found\n' "${failed}" >&2
  exit 1
fi

# A workflow that was read and carried no disallowed secret and a
# workflow that was never read because no PR trigger put it in scope both
# leave this lint silent. Say which happened: an operator reading a green
# run needs to know whether the rule was applied or the file was out of
# scope, and a trigger change that quietly moves a workflow out of scope
# shows up here as a scanned count that dropped.
printf '%s: examined %d workflow(s): %d scanned as PR-triggered, %d skipped as not PR-triggered; %d secrets.GITHUB_TOKEN reference(s) allowed\n' \
  'pr-workflows-no-secrets' "${examined}" "${scanned}" "${skipped}" "${allowed}"
exit 0
