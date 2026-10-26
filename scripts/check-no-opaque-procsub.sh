#!/usr/bin/env bash
# scripts/check-no-opaque-procsub.sh
#
# @description Lint: no script anywhere under `scripts/` and no workflow
# or composite-action `run:` body feeds a redirection from a process
# substitution. A substitution runs in its own subshell, so `set -Eeuo
# pipefail` only ever sees the status of the command the redirection
# feeds — never the producer's. A failed producer hands the consumer
# empty output to score as data: either a clean pass that flags nothing
# (fail-open) or a substantive violation the input never showed (a
# tooling fault misdiagnosed as drift). That property holds for whatever
# the producer is, so the rule does not ask: every `< <(...)` is a hit,
# with no exemption.
#
# `diff <(...) <(...)` stays legal: diff consumes both substitutions as
# file arguments and its own exit status is what the caller acts on, so
# no status is lost.
#
# Use the capture-into-variable idiom (or a temp file for NUL-delimited
# output) so a producer failure aborts loudly.
#
# The script scan recurses. A shared library under `scripts/lib/` runs
# inside whichever caller sources it, so a lost producer status there is
# lost for every script in the tree at once — the widest blast radius the
# banned shape has, and the one a top-level-only glob never reads.
#
# Workflow and composite-action YAML is matched on each step's extracted
# `run:` body, never on raw YAML, so the line a hit names is the line
# within that body. The YAML scan set is `.github/workflows/*.yml` (or
# `.yaml`) — the top level only, the one GitHub reads — and every
# `.github/actions/**/action.yml` (or `.yaml`), less any action path with
# a `fixtures/` segment. Neither root reaches `tests/fixtures/`, whose
# trees exist to hold violations.
#
# A step list or `run:` body written as an alias (`steps: *st`,
# `run: *body`) is read as its anchored text; a step list that still
# holds an alias after resolving is refused with exit 2.
#
# Honors SCRIPTS_DIR_OVERRIDE (default: scripts), WORKFLOWS_DIR_OVERRIDE
# (default: .github/workflows) and ACTIONS_DIR_OVERRIDE (default:
# .github/actions) for fixtures.
# Exit 0 clean, 1 on any hit, 2 on operational error: `yq` is missing, a
# scan set is empty, `grep` cannot read a shell script, `yq` cannot read
# a workflow or action file or one of its steps, or a step list still
# holds an alias after resolving.
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

require_tool yq

readonly DIR="${SCRIPTS_DIR_OVERRIDE:-scripts}"
readonly WORKFLOWS_DIR="${WORKFLOWS_DIR_OVERRIDE:-.github/workflows}"
readonly ACTIONS_DIR="${ACTIONS_DIR_OVERRIDE:-.github/actions}"
[[ -d ${DIR} ]] || {
  printf 'scripts dir not found: %s\n' "${DIR}" >&2
  exit 2
}

# A redirection operator, whitespace, then a substitution. The bracket
# escapes keep this file's own pattern-definition line from matching
# itself. Whitespace is required because bash reads `<<` as a heredoc, so
# a redirection can only reach a substitution across a gap.
readonly REDIR_PATTERN='<[[:space:]]+<[(]'
# Doc comments are allowed to name the banned idiom (e.g. explaining why
# a script uses the capture idiom instead); only live code is a hit.
readonly COMMENT_LINE='^[0-9]+:[[:space:]]*#'

readonly HIT_DIAG='process substitution feeds a redirection (producer exit status lost to its subshell)'

# @description Print every live-code line of the input that feeds a
# redirection from a substitution, as `<line>:<text>`.
# @arg $1 file to read, or `-` for stdin
# @exitcode 0 on a hit, 1 on none, above 1 when the input could not be read
function procsub_hits() {
  # The matching grep is captured on its own: piped into the comment
  # filter, a read failure (2) leaves the filter empty input, and the
  # filter's own 1 would become the status, scoring an unread file as
  # one with no hit.
  local matches status=0
  matches="$(grep --extended-regexp --line-number -- "${REDIR_PATTERN}" "$1")" || status=$?
  if ((status != 0)); then
    return "${status}"
  fi
  grep --invert-match --extended-regexp -- "${COMMENT_LINE}" <<<"${matches}"
}

# Emits one `<shape>|<document>|<job position>|<step index>` row per step
# carrying a `run:` key, from both `jobs.<id>.steps` (workflow) and
# `runs.steps` (composite action). The job position is empty for a
# composite. A row holds only numbers and words `yq` prints, never a job
# key: a key is free text and could hold the `|` separator.
#
# A step list written as an alias (`steps: *st`) is read as the anchored
# list. `to_entries` does not follow an alias, so the list is resolved
# first, in two `explode` passes: one pass leaves the aliases inside the
# copy it makes (a step `- *s`, a body `run: *body`), and the second
# resolves those. A list still holding an alias after both passes emits
# one `job-alias` or `composite-alias` row in place of its steps, and the
# run stops on it rather than read a list it has not resolved.
# shellcheck disable=SC2016 # yq expression: literal $ refs, not shell expansion
readonly STEPS_HOLD_ALIAS='([$s | .. | select(kind == "alias")] | length) > 0'
# shellcheck disable=SC2016 # yq expression: literal $ refs, not shell expansion
readonly ROWS_QUERY="document_index as \$d | ((((${JOBS_NODE}) // {}) | to_entries | to_entries[] as \$j | ((\$j.value.value.steps | explode(.) | explode(.)) // []) as \$s | if ${STEPS_HOLD_ALIAS} then \"job-alias|\" + (\$d | tostring) + \"|\" + (\$j.key | tostring) + \"|\" else (\$s | to_entries[] | select(.value.run != null) | \"job|\" + (\$d | tostring) + \"|\" + (\$j.key | tostring) + \"|\" + (.key | tostring)) end), (((.runs.steps | explode(.) | explode(.)) // []) as \$s | if ${STEPS_HOLD_ALIAS} then \"composite-alias|\" + (\$d | tostring) + \"||\" else (\$s | to_entries[] | select(.value.run != null) | \"composite|\" + (\$d | tostring) + \"||\" + (.key | tostring)) end))"

failed=0
shopt -s nullglob globstar
# `globstar` is set here and left set across the calls, so the patterns
# keep reaching every nested directory under each scan root.
declare -a repo_scripts=() yaml_candidates=()
glob_into repo_scripts 'repo shell scripts' "${DIR}/**/*.sh"
glob_into yaml_candidates 'workflow and composite-action files' \
  "${WORKFLOWS_DIR}/*.yml" "${WORKFLOWS_DIR}/*.yaml" \
  "${ACTIONS_DIR}/**/action.yml" "${ACTIONS_DIR}/**/action.yaml"
shopt -u nullglob globstar

declare -a yaml_files=()
for path in "${yaml_candidates[@]}"; do
  rel="${path#"${ACTIONS_DIR}/"}"
  if [[ ${rel} != "${path}" && (${rel} == fixtures/* || ${rel} == */fixtures/*) ]]; then
    continue
  fi
  yaml_files+=("${path}")
done

for f in "${repo_scripts[@]}"; do
  # grep's status is read three ways rather than as a boolean: no hit in
  # this file (1) is the clean answer, but a grep that could not read the
  # file (2) scored as "no hit" would vouch for a file nothing examined.
  status=0
  hits="$(procsub_hits "${f}")" || status=$?
  if ((status > 1)); then
    printf 'could not scan %s for process substitutions\n' "${f}" >&2
    exit 2
  fi
  while IFS= read -r hit; do
    [[ -z ${hit} ]] && continue
    printf '%s: %s: %s\n' "${f}" "${HIT_DIAG}" "${hit}" >&2
    failed=$((failed + 1))
  done <<<"${hits}"
done

run_blocks=0
for path in ${yaml_files+"${yaml_files[@]}"}; do
  # A refused job key could shift the job positions the rows below name,
  # so the file is not read around it.
  if ! odd_key="$(first_odd_job_key "${path}")"; then
    printf '%s: could not evaluate workflow or action with yq (malformed?)\n' "${path}" >&2
    exit 2
  fi
  if [[ -n ${odd_key} ]]; then
    odd_job_key_message "${path}" "${odd_key}" >&2
    exit 2
  fi
  if ! rows="$(yq eval "${YQ_MERGE_SPEC[@]}" "${ROWS_QUERY}" "${path}")"; then
    printf '%s: could not evaluate workflow or action with yq (malformed?)\n' "${path}" >&2
    exit 2
  fi
  while IFS='|' read -r shape doc jpos idx; do
    [[ -n ${shape} ]] || continue
    # The row numbers reach `yq` as data, through `env`. A body written as
    # an alias (`run: *body`) is resolved to its anchored text, which is
    # what the runner executes; read as is it would be the alias name.
    if [[ ${shape} == composite-alias ]]; then
      printf '%s: runs.steps still holds a YAML alias after resolving; cannot read it\n' "${path}" >&2
      exit 2
    fi
    if [[ ${shape} == composite ]]; then
      if ! body="$(DOC="${doc}" IDX="${idx}" yq eval "${YQ_MERGE_SPEC[@]}" 'select(document_index == env(DOC)) | .runs.steps[env(IDX)].run | explode(.)' "${path}")"; then
        printf '%s: cannot read composite step[%s] run: block\n' "${path}" "${idx}" >&2
        exit 2
      fi
      where="$(printf 'composite step[%s]' "${idx}")"
    else
      if ! job="$(DOC="${doc}" JPOS="${jpos}" yq eval "${YQ_MERGE_SPEC[@]}" 'select(document_index == env(DOC)) | '"${JOBS_NODE}"' | to_entries | .[env(JPOS)].key | explode(.)' "${path}")"; then
        printf '%s: cannot read the key of the job at position %s\n' "${path}" "${jpos}" >&2
        exit 2
      fi
      if [[ ${shape} == job-alias ]]; then
        printf '%s: jobs.%q.steps still holds a YAML alias after resolving; cannot read it\n' "${path}" "${job}" >&2
        exit 2
      fi
      if ! body="$(DOC="${doc}" JPOS="${jpos}" IDX="${idx}" yq eval "${YQ_MERGE_SPEC[@]}" 'select(document_index == env(DOC)) | '"${JOBS_NODE}"' | to_entries | .[env(JPOS)].value.steps[env(IDX)].run | explode(.)' "${path}")"; then
        printf '%s: cannot read job %q step[%s] run: block\n' "${path}" "${job}" "${idx}" >&2
        exit 2
      fi
      where="$(printf 'job %q step[%s]' "${job}" "${idx}")"
    fi
    run_blocks=$((run_blocks + 1))
    status=0
    hits="$(procsub_hits - <<<"${body}")" || status=$?
    if ((status > 1)); then
      printf '%s: could not scan %s run: block for process substitutions\n' "${path}" "${where}" >&2
      exit 2
    fi
    while IFS= read -r hit; do
      [[ -z ${hit} ]] && continue
      printf '%s: %s run: line %s: %s: %s\n' "${path}" "${where}" "${hit%%:*}" "${HIT_DIAG}" "${hit#*:}" >&2
      failed=$((failed + 1))
    done <<<"${hits}"
  done <<<"${rows}"
done

if ((failed > 0)); then
  printf '%d opaque process-substitution site(s) found\n' "${failed}" >&2
  exit 1
fi
printf 'no-opaque-procsub: ok — scanned %d shell script(s) and %d run: block(s)\n' \
  "${#repo_scripts[@]}" "${run_blocks}"
exit 0
