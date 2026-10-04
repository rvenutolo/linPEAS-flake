#!/usr/bin/env bash
# scripts/check-run-block-strict.sh
#
# @description Lint: every block-scalar or newline-carrying `run:`
# block under `.github/workflows/*.yml` (or `.yaml`) and
# `.github/actions/**/action.yml` (or `.yaml`) starts with
# `set -Eeuo pipefail` as its first non-blank, non-comment line.

# Lint: every block-scalar or newline-carrying `run:` block under
# `.github/workflows/*.yml` (or `.yaml`) and
# `.github/actions/**/action.yml` (or `.yaml`) starts with
# `set -Eeuo pipefail` as its first non-blank, non-comment line.
#
# Actions runs a workflow `run:` block as `bash -e {0}` and a composite
# `shell: bash` block as `bash --noprofile --norc -eo pipefail {0}`.
# Neither shape enables `-u` or `-E`, and a workflow block gets no
# `pipefail`, so a failing pipeline stage or an unset-variable
# expansion produces wrong results without failing the step — in
# security-critical jobs (release signing, attestation verify, pin
# write-back) that is a silent bad output. The strict-mode prelude
# (`-e` aborts on failure, `-E` propagates ERR traps into subshells,
# `-u` rejects unset variables, `-o pipefail` makes pipelines fail on
# any stage) closes that gap uniformly.
#
# Composite actions carry the same exposure with a wider blast radius:
# one composite runs inside every job that calls it, so a block there
# that swallows a failure swallows it everywhere. Their steps hang off
# `runs.steps` rather than `jobs.<id>.steps`, so both shapes are read.
#
# Threshold: block scalar (`|`, `>`, and their chomping/indent
# variants) OR an evaluated value carrying a newline. Newline
# presence alone under-detects: a folded scalar (`run: >-`) reads as
# several `;`-separated commands across several source lines but
# folds to one newline-free string, so a block that plainly runs a
# command sequence would otherwise escape the requirement. Node
# style, which survives folding, catches it.
#
# Plain single-line `run:` invocations stay exempt — they are
# already a single shell command whose exit status drives the step
# directly. The prelude would just be noise.
#
# See docs/security/workflow-hardening.md.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER (workflow
# fixtures) and ACTIONS_DIR_OVERRIDE (composite-action fixtures).
# Setting either override scans only what the overrides name, so a
# fixture run never reaches the real .github/ tree.
# Exits 0 on full coverage, 1 on any drift. Exits 2 when the check
# cannot run: `yq` is absent from PATH, the workflow and
# composite-action globs match no file, WORKFLOW_FILE_FILTER selects
# none of the files they matched, or a read of one step's run: block or
# its job's key fails once the file's steps have been listed. An empty scan set is a could-not-run
# rather than a clean tree; LINT_ALLOW_EMPTY_SCAN=1 accepts one
# deliberately.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"

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

readonly WANT='set -Eeuo pipefail'

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 2
fi

# Selects the step entries whose run: is a block scalar or carries a
# newline. `style` reports `folded` / `literal` for block scalars and is
# empty for a plain one-line command.
readonly MULTILINE_SELECT='select(.value.run != null and ((.value.run | contains("\n")) or (.value.run | style) == "folded" or (.value.run | style) == "literal"))'

# Emits one `<shape>|<document>|<job position>|<step index>` row per
# multi-line run: block. Both document shapes are read from every file:
# `jobs.<id>.steps` (workflow) and `runs.steps` (composite action). The
# job position is empty for a composite, which has no job layer. A row holds
# only words and numbers `yq` prints, never a job key: a key is free
# text, and one holding the `|` separator would move its own text into
# the index. The reads below find the job by its document and position.
# shellcheck disable=SC2016 # yq expression: literal $ refs, not shell expansion
readonly ROWS_QUERY="document_index as \$d | (((.jobs // {}) | to_entries | to_entries[] as \$j | (\$j.value.value.steps // []) | to_entries[] | ${MULTILINE_SELECT} | \"job|\" + (\$d | tostring) + \"|\" + (\$j.key | tostring) + \"|\" + (.key | tostring)), ((.runs.steps // []) | to_entries[] | ${MULTILINE_SELECT} | \"composite|\" + (\$d | tostring) + \"||\" + (.key | tostring)))"

# Return first non-blank, non-comment line of a run: block.
# Args: run-body-on-stdin
first_meaningful_line() {
  awk '
    /^[[:space:]]*$/  { next }
    /^[[:space:]]*#/  { next }
    { sub(/^[[:space:]]+/, ""); print; exit }
  '
}

# Patterns are collected as strings and expanded inside `glob_into`, which
# asserts the match set is non-empty. A merge-gate lint whose whole scan set
# expands to nothing prints nothing and exits 0 — byte-identical to a clean
# run over a fully compliant tree. The assertion is over the union rather than
# per pattern because a repo may hold workflows and no composite actions;
# only both roots coming up empty is the could-not-run.
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

  if ! rows="$(yq eval "${ROWS_QUERY}" "${f}")"; then
    printf '%s: could not evaluate workflow or action with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi
  while IFS='|' read -r shape doc jpos idx; do
    [[ -z ${shape} ]] && continue
    # The rows query above proves the step exists, not that this read of
    # its body succeeds. A yq that dies here has read no run: block, and
    # its exit 1 would surface as a strict-mode violation in a block
    # nothing was read from. The row's numbers reach `yq` as data, through
    # `env`.
    if [[ ${shape} == composite ]]; then
      if ! body="$(DOC="${doc}" IDX="${idx}" yq eval 'select(document_index == env(DOC)) | .runs.steps[env(IDX)].run' "${f}")"; then
        printf '%s: cannot read composite step[%s] run: block\n' "${f}" "${idx}" >&2
        exit 2
      fi
      where="$(printf 'composite step[%s]' "${idx}")"
    else
      if ! job="$(DOC="${doc}" JPOS="${jpos}" yq eval 'select(document_index == env(DOC)) | .jobs | to_entries | .[env(JPOS)].key | explode(.)' "${f}")"; then
        printf '%s: cannot read the key of the job at position %s\n' "${f}" "${jpos}" >&2
        exit 2
      fi
      if ! body="$(DOC="${doc}" JPOS="${jpos}" IDX="${idx}" yq eval 'select(document_index == env(DOC)) | .jobs | to_entries | .[env(JPOS)].value.steps[env(IDX)].run' "${f}")"; then
        printf '%s: cannot read job %q step[%s] run: block\n' "${f}" "${job}" "${idx}" >&2
        exit 2
      fi
      where="$(printf 'job %q step[%s]' "${job}" "${idx}")"
    fi
    first="$(printf '%s\n' "${body}" | first_meaningful_line || true)"
    if [[ ${first} == "${WANT}"* ]]; then
      continue
    fi
    printf '%s: %s run: block must start with %q (got %q)\n' \
      "${f}" "${where}" "${WANT}" "${first}" >&2
    failed=$((failed + 1))
  done <<<"${rows}"
done

if ((failed > 0)); then
  printf '%d run: block(s) missing strict-mode prelude\n' "${failed}" >&2
  exit 1
fi
exit 0
