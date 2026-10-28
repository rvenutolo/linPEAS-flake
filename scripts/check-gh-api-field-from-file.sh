#!/usr/bin/env bash
# scripts/check-gh-api-field-from-file.sh
#
# @description Lint: no `gh api` call in a workflow or composite-action
# `run:` block passes a file's contents as one `--field`, `--raw-field`,
# `-f` or `-F` argument. A request body built from a file goes to
# `gh api --input -` on stdin.

# Lint: no `gh api` call in a workflow or composite-action `run:` block
# passes a file's contents as one `--field`, `--raw-field`, `-f` or `-F`
# argument.
#
# Linux caps a single argument at 128 KiB (`MAX_ARG_STRLEN`). A call such
# as `--field content="$(base64 --wrap=0 FILE)"` works until the file
# grows past that cap, then fails every run with `Argument list too long`
# (exit 126). The failure is deterministic and arrives with no change to
# the workflow: the file just grew. The body goes on stdin instead, built
# with `jq --rawfile` and passed as `gh api --input -`, which has no size
# cap. `-F name=@FILE` is also fine: gh reads that file itself.
#
# --- What counts as file contents -----------------------------------------
#
# A value word holds file contents when it carries a command substitution
# whose output stage reads a file, or expands a variable this block
# assigned from one. The output stage is the last command of the
# substitution's last statement, and of a pipeline its last stage, so
# `$(cat f | base64)` counts and `$(jq --rawfile ... | gh api --input -)`
# does not: the value is what gh printed, not the file. An output stage
# reads a file when it is:
#
#   * `base64`
#   * `cat`, unless its only input is a here-document
#   * `jq` with `--rawfile`, `--slurpfile`, `--slurp`, `--raw-input`, or a
#     short-flag bundle holding `s` or `R`
#   * a bare redirect, `$(<FILE)`
#
# Other `jq` reads (`jq -r .sha FILE`) print one small value and do not
# count. A variable counts once assigned from such a value, directly or
# through another counted variable (`b="${a}"`); an expansion inside a
# nested substitution does not pass it on, because that value is the
# nested command's output. `${#x}` is a length and does not count.
#
# --- Where the arguments are read -----------------------------------------
#
# The arguments of each `gh api` command, and every array literal
# (`args=(...)`, `args+=(...)`) in a block that runs `gh api`, since an
# argument list is often built in an array and passed as
# `gh api "${args[@]}"`. A flag word is read with the word after it
# (`--field name=value`) or with its value attached (`--field=name=value`,
# `-fname=value`).
#
# Command words come from `shfmt --tojson`, not from a text scan: an
# invocation inside `$(...)`, a value split across backslash-continued
# lines, and a mention of `gh api` in a message string all read correctly
# only from the parse tree. A `${{ ... }}` expression is replaced by a
# literal word before parsing, because the shell never sees one: the
# runner substitutes it first.
#
# --- Declared blind spots -------------------------------------------------
#
# A value carried between steps (`$GITHUB_ENV`, step outputs, a file), a
# variable set by `read`, `mapfile` or `printf -v`, a call made through a
# shell function or through a command word that is itself an expansion,
# and an array assigned in one block and used in another are not
# followed. Only a block that spells `gh` is parsed, since no other block
# can hold a `gh api` command word. Such a block is read as bash whatever
# its `shell:` says, so a step in another language is reported as
# unparsable when `shfmt` rejects it, and is scanned as bash when it
# does not, rather than skipped.
#
# A job key the job list cannot carry (see scripts/lib/job-keys.sh) is a
# counted finding, and the file's jobs are not read.
#
# See docs/security/workflow-hardening.md.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER (workflow
# fixtures) and ACTIONS_DIR_OVERRIDE (composite-action fixtures).
# Setting either override scans only what the overrides name, so a
# fixture run never reaches the real .github/ tree.
# Exits 0 when no call passes file contents as an argument, 1 on any
# offender, unreadable workflow or unparsable run: block, 2 when the scan
# could not run: `yq`, `shfmt`, `jq` or `base64` is absent, the workflow
# and composite-action globs match no file, WORKFLOW_FILE_FILTER selects
# none of the files they matched, a read of one step's run: block or its
# job's key fails once the file's steps have been listed, a block read
# that way cannot be decoded, or `jq` fails reading a block's parse tree.
# LINT_ALLOW_EMPTY_SCAN=1 accepts an empty scan set.
#
# payload-subject-exempt: matches only because it names the literal string "gh api" as the pattern it reports on — it issues no API call, and its input is this repo's own workflow YAML read through yq and shfmt, whose unreadable and unparsable cases it already reports

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/job-keys.sh
source "${_lib_dir}/lib/job-keys.sh"

readonly DEFAULT_WORKFLOWS_DIR=".github/workflows"
readonly DEFAULT_ACTIONS_DIR=".github/actions"
readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"

workflows_dir="${WORKFLOWS_DIR_OVERRIDE:-}"
actions_dir="${ACTIONS_DIR_OVERRIDE:-}"
if [[ -z ${workflows_dir} && -z ${actions_dir} ]]; then
  workflows_dir="${DEFAULT_WORKFLOWS_DIR}"
  actions_dir="${DEFAULT_ACTIONS_DIR}"
fi
readonly workflows_dir actions_dir

require_tool yq
require_tool shfmt
require_tool jq
require_tool base64

# Selects every step entry that has a run: block.
readonly RUN_SELECT='select(.value.run != null)'

# The block's text as the shell will see it, base64-encoded so it fits on
# one row. A body written as an alias (`run: *body`) is read as its
# anchored text. Each `${{ ... }}` expression is replaced with a literal
# word first, because the runner substitutes it before the shell runs.
# The match is the shortest run up to the first `}}`, so an expression
# whose string literal holds `}}` is cut short there.
readonly BODY_B64='(.value.run | explode(.) | sub("\$\{\{(?s:.)*?\}\}"; "GHEXPR") | @base64)'

# Emits one `<shape>|<document>|<job position>|<step index>|<body>` row
# per run: block, from `jobs.<id>.steps` (workflow) and `runs.steps`
# (composite action). A row holds only words and numbers `yq` prints and
# the base64 body, never a job key: a key is free text, and one holding
# the `|` separator would move its own text into the index. A step list
# written as an alias (`steps: *st`) is read as its anchored list. Every
# body comes from this one read, so a file costs one `yq` run however
# many steps it holds.
# shellcheck disable=SC2016 # yq expression: literal $ refs, not shell expansion
readonly ROWS_QUERY="document_index as \$d | ((((${JOBS_NODE}) // {}) | to_entries | to_entries[] as \$j | ((\$j.value.value.steps | explode(.)) // []) | to_entries[] | ${RUN_SELECT} | \"job|\" + (\$d | tostring) + \"|\" + (\$j.key | tostring) + \"|\" + (.key | tostring) + \"|\" + ${BODY_B64}), (((.runs.steps | explode(.)) // []) | to_entries[] | ${RUN_SELECT} | \"composite|\" + (\$d | tostring) + \"||\" + (.key | tostring) + \"|\" + ${BODY_B64}))"

# One record per offending argument, as `line<TAB>flag<TAB>name`. The
# name is the literal text before the value's first `=`, or `-` when it
# has none, because a tab is IFS whitespace and an empty middle field
# would collapse.
#
# shellcheck disable=SC2016 # jq program text: $taint and friends are jq bindings, not shell expansions
readonly JQ_PROGRAM='
def lit: if (.Parts? | type) == "array" and (.Parts | all(.Type? == "Lit"))
  then ([.Parts[].Value] | join("")) else null end;
def calls: [ .. | objects | select(.Type? == "CallExpr")
  | select(((.Args // []) | length) > 0) ];
def cmdword: (.Args[0] | lit);
def last_stmt: if .Cmd.Type? == "BinaryCmd" then (.Cmd.Y | last_stmt) else . end;
def jq_file_flags: any(.[]; test("^--(rawfile|slurpfile|slurp|raw-input)$")
  or test("^-[A-Za-z]*[sR][A-Za-z]*$"));
def heredoc_only: ((.Cmd.Args | length) == 1) and ((.Redirs // []) | length) > 0
  and ((.Redirs // []) | all(.Hdoc != null));
def file_stmt: (.Cmd == null and ((.Redirs // []) | length) > 0)
  or (.Cmd as $c
      | ($c.Type? == "CallExpr") and ((($c.Args // []) | length) > 0)
      and (($c | cmdword) as $w
        | ($w == "base64")
          or ($w == "cat" and (heredoc_only | not))
          or ($w == "jq" and ([$c.Args[1:][] | lit | select(. != null)] | jq_file_flags))));
def reads_file: [ .. | objects | select(.Type? == "CmdSubst") ]
  | any(.[]; ((.Stmts // []) | last) as $s | $s != null and ($s | last_stmt | file_stmt));
def shallow: def r: ., (if type == "object"
    then (if .Type? == "CmdSubst" then empty else (.[] | r) end)
    elif type == "array" then (.[] | r) else empty end); r;
def params: [ shallow | objects | select(.Type? == "ParamExp")
  | select(.Length? != true) | .Param.Value? | select(type == "string") ];
def tainted($t): reads_file or (params | any(.[]; . as $p | $t | index($p)));
def assigns: [ .. | objects | select((.Name? | type) == "object")
  | select((.Name.Value? | type) == "string")
  | select(has("Value") or has("Array")) ];
def lead: [ .Parts[]? | if .Type? == "DblQuoted" then .Parts[0]? else . end
  | select(.Type? == "Lit") | .Value ] | first // "";
def name_of($skip): (lead[$skip:] | split("=")) as $s
  | if ($s | length) > 1 and ($s[0] | length) > 0 then $s[0] else "-" end;
. as $root
| ($root | assigns) as $as
| ([ $as[] | select(.Value != null) ]) as $scalars
| ( [] | until(
      . as $t | ([ $scalars[] | select(.Value | tainted($t)) | .Name.Value ] | unique) - $t == [];
      . as $t | ([ $scalars[] | select(.Value | tainted($t)) | .Name.Value ] + $t | unique)) ) as $taint
| ($root | calls | map(select(cmdword == "gh" and ((.Args[1] // {}) | lit) == "api"))) as $gh
| def offenders:
    . as $ws | range(0; $ws | length) as $i | ($ws[$i] | lit) as $l
    | (($ws[$i].Parts[0].Value? // "") | [capture("^(?<f>--field=|--raw-field=|-f|-F)(?<rest>.+)")?] | first) as $att
    | if ($l != null) and (["--field", "--raw-field", "-f", "-F"] | index($l)) then
        select($i + 1 < ($ws | length)) | select($ws[$i + 1] | tainted($taint))
        | [($ws[$i].Pos.Line), $l, ($ws[$i + 1] | name_of(0))]
      elif ($l == null) and ($att != null) then
        select($ws[$i] | tainted($taint))
        | [($ws[$i].Pos.Line), ($att.f | rtrimstr("=")), ($ws[$i] | name_of($att.f | length))]
      else empty end;
  ( $gh[] | .Args | offenders ),
  ( if ($gh | length) > 0
      then ($as[] | select(.Array != null) | [(.Array.Elems // [])[].Value] | offenders)
      else empty end )
| @tsv
'

# @description Print this block's offender records, or return 1 when
# `shfmt` cannot parse it. Exits 2 when `jq` fails on the parse tree,
# which is a could-not-run, not a finding.
# @arg $1 run: block text, expressions already replaced
function records_of() {
  local -r body="$1"
  local tree
  if ! tree="$(shfmt --tojson <<<"${body}" 2>/dev/null)"; then
    return 1
  fi
  if ! jq --raw-output "${JQ_PROGRAM}" <<<"${tree}"; then
    log_err "jq failed reading a shfmt parse tree"
    exit 2
  fi
}

# Patterns are collected as strings and expanded inside `glob_into`, which
# asserts the match set is non-empty: a scan set that expands to nothing
# would print nothing and exit 0, byte-identical to a clean tree. Only
# both roots coming up empty is the could-not-run, because a repo may hold
# workflows and no composite actions.
declare -a patterns=()
if [[ -n ${workflows_dir} && -d ${workflows_dir} ]]; then
  patterns+=("${workflows_dir}/*.yml" "${workflows_dir}/*.yaml")
fi
if [[ -n ${actions_dir} && -d ${actions_dir} ]]; then
  # `**` also matches zero segments, so this covers both
  # `<dir>/<name>/action.yml` and a bare `<dir>/action.yml`.
  patterns+=("${actions_dir}/**/action.yml" "${actions_dir}/**/action.yaml")
fi
declare -a files=()
shopt -s globstar
glob_into files 'workflow and composite-action files' ${patterns+"${patterns[@]}"}
shopt -u globstar
declare -a selected_files=()
filter_into selected_files 'workflow and composite-action files' "${FILE_FILTER}" "${files[@]}"

failed=0
for f in "${selected_files[@]}"; do
  [[ -f ${f} ]] || continue

  # A job key the job list cannot carry is a finding, and the file's jobs
  # are not read: the rows below name a job by its position, which a
  # refused key would shift or hide.
  if ! odd_keys="$(first_odd_job_key "${f}")"; then
    printf '%s: could not evaluate workflow or action with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi
  odd_key=''
  while IFS= read -r line; do
    if [[ -n ${line} ]]; then
      odd_key="${line}"
      break
    fi
  done <<<"${odd_keys}"
  if [[ -n ${odd_key} ]]; then
    odd_job_key_message "${f}" "${odd_key}" >&2
    failed=$((failed + 1))
    continue
  fi
  if ! rows="$(yq eval "${YQ_MERGE_SPEC[@]}" "${ROWS_QUERY}" "${f}")"; then
    printf '%s: could not evaluate workflow or action with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi
  while IFS='|' read -r shape doc jpos idx b64; do
    [[ -z ${shape} ]] && continue
    if ! body="$(base64 --decode <<<"${b64}")"; then
      printf '%s: cannot decode the run: block read from document %s step[%s]\n' "${f}" "${doc}" "${idx}" >&2
      exit 2
    fi
    # A block that never spells `gh` holds no `gh api` command word, so it
    # is not parsed: most blocks are this, and parsing costs two process
    # starts each.
    [[ ${body} == *gh* ]] || continue
    parsed=1
    rc=0
    records="$(records_of "${body}")" || rc=$?
    case ${rc} in
    0) ;;
    1) parsed=0 ;;
    *) exit 2 ;;
    esac
    [[ ${parsed} == 0 || -n ${records} ]] || continue
    if [[ ${shape} == composite ]]; then
      where="$(printf 'composite step[%s]' "${idx}")"
    else
      # The key is read only for a diagnostic. The row's numbers reach
      # `yq` as data, through `env`.
      if ! job="$(DOC="${doc}" JPOS="${jpos}" yq eval "${YQ_MERGE_SPEC[@]}" 'select(document_index == env(DOC)) | '"${JOBS_NODE}"' | to_entries | .[env(JPOS)].key | explode(.)' "${f}")"; then
        printf '%s: cannot read the key of the job at position %s\n' "${f}" "${jpos}" >&2
        exit 2
      fi
      where="$(printf 'job %q step[%s]' "${job}" "${idx}")"
    fi
    if [[ ${parsed} == 0 ]]; then
      printf '%s: %s run: block cannot be parsed as bash\n' "${f}" "${where}" >&2
      failed=$((failed + 1))
      continue
    fi
    while IFS=$'\t' read -r line flag name; do
      [[ -n ${line} ]] || continue
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      printf '%s: %s run: line %s: gh api %s value is built from file contents; send the body on stdin with `--input -`: %s\n' \
        "${f}" "${where}" "${line}" "${flag}" "${name}" >&2
      failed=$((failed + 1))
    done <<<"${records}"
  done <<<"${rows}"
done

if ((failed > 0)); then
  printf '%d gh api argument(s) carry file contents or could not be read\n' "${failed}" >&2
  exit 1
fi
exit 0
