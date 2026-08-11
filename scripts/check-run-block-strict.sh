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
# Bash inside `run:` blocks defaults to `-e` off. A failed command in
# the middle of a block that runs several commands silently
# continues, producing wrong results in security-critical jobs
# (release signing, attestation verify, pin write-back). The
# strict-mode prelude (`-e` aborts on failure, `-E` propagates ERR
# traps into subshells, `-u` rejects unset variables, `-o pipefail`
# makes pipelines fail on any stage) closes that gap.
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
# Exits 0 on full coverage, 1 on any drift.

set -Eeuo pipefail
IFS=$'\n\t'

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

# Emits one `<shape>|<job>|<index>` row per multi-line run: block. Both
# document shapes are read from every file: `jobs.<id>.steps` (workflow)
# and `runs.steps` (composite action). The job field is empty for a
# composite, which has no job layer.
# shellcheck disable=SC2016 # yq expression: literal $ refs, not shell expansion
readonly ROWS_QUERY="((.jobs // {}) | to_entries[] as \$j | (\$j.value.steps // []) | to_entries[] | ${MULTILINE_SELECT} | \"job|\" + \$j.key + \"|\" + (.key | tostring)), ((.runs.steps // []) | to_entries[] | ${MULTILINE_SELECT} | \"composite||\" + (.key | tostring))"

# Return first non-blank, non-comment line of a run: block.
# Args: run-body-on-stdin
first_meaningful_line() {
  awk '
    /^[[:space:]]*$/  { next }
    /^[[:space:]]*#/  { next }
    { sub(/^[[:space:]]+/, ""); print; exit }
  '
}

files=()
shopt -s nullglob globstar
if [[ -n ${workflows_dir} && -d ${workflows_dir} ]]; then
  files+=("${workflows_dir}"/*.yml "${workflows_dir}"/*.yaml)
fi
if [[ -n ${actions_dir} && -d ${actions_dir} ]]; then
  # `**` also matches zero segments, so this covers both
  # `<dir>/<name>/action.yml` and a bare `<dir>/action.yml`.
  files+=("${actions_dir}"/**/action.yml "${actions_dir}"/**/action.yaml)
fi
shopt -u nullglob globstar

failed=0
for f in "${files[@]}"; do
  [[ -f ${f} ]] || continue
  if [[ -n ${FILE_FILTER} && "$(basename "${f}")" != "${FILE_FILTER}" ]]; then
    continue
  fi

  if ! rows="$(yq eval "${ROWS_QUERY}" "${f}")"; then
    printf '%s: could not evaluate workflow or action with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi
  while IFS='|' read -r shape job idx; do
    [[ -z ${shape} ]] && continue
    if [[ ${shape} == composite ]]; then
      body="$(yq eval ".runs.steps[${idx}].run" "${f}")"
      where="$(printf 'composite step[%s]' "${idx}")"
    else
      body="$(yq eval ".jobs.\"${job}\".steps[${idx}].run" "${f}")"
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
