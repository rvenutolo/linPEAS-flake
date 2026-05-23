#!/usr/bin/env bash
# scripts/check-run-block-strict.sh
#
# Lint: every multi-line `run:` block under
# `.github/workflows/*.yml` starts with `set -Eeuo pipefail` as its
# first non-blank, non-comment line.
#
# Bash inside `run:` blocks defaults to `-e` off. A failed command in
# the middle of a multi-line block silently continues, producing
# wrong results in security-critical jobs (release signing,
# attestation verify, pin write-back). The strict-mode prelude
# (`-e` aborts on failure, `-E` propagates ERR traps into subshells,
# `-u` rejects unset variables, `-o pipefail` makes pipelines fail
# on any stage) closes that gap.
#
# Threshold: multi-line only. Single-line `run:` invocations are
# already a single shell command; their exit status drives the step
# directly. The prelude would just be noise.
#
# See docs/security/workflow-hardening.md.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER for fixtures.
# Exits 0 on full coverage, 1 on any drift.

set -Eeuo pipefail
IFS=$'\n\t'

readonly DEFAULT_DIR=".github/workflows"
readonly OVERRIDE="${WORKFLOWS_DIR_OVERRIDE:-}"
readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
readonly DIR="${OVERRIDE:-${DEFAULT_DIR}}"

readonly WANT='set -Eeuo pipefail'

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 2
fi

# Return first non-blank, non-comment line of a run: block.
# Args: run-body-on-stdin
first_meaningful_line() {
  awk '
    /^[[:space:]]*$/  { next }
    /^[[:space:]]*#/  { next }
    { sub(/^[[:space:]]+/, ""); print; exit }
  '
}

failed=0
shopt -s nullglob
for f in "${DIR}"/*.yml "${DIR}"/*.yaml; do
  [[ -f ${f} ]] || continue
  if [[ -n ${FILE_FILTER} && "$(basename "${f}")" != "${FILE_FILTER}" ]]; then
    continue
  fi

  # Enumerate (job, step-index) pairs that have a multi-line run:.
  # shellcheck disable=SC2016 # yq expression: literal $ refs, not shell expansion
  while IFS='|' read -r job idx; do
    [[ -z ${job} ]] && continue
    body="$(yq eval ".jobs.\"${job}\".steps[${idx}].run" "${f}")"
    first="$(printf '%s\n' "${body}" | first_meaningful_line || true)"
    if [[ ${first} == "${WANT}"* ]]; then
      continue
    fi
    printf '%s: job %q step[%s] multi-line run: must start with %q (got %q)\n' \
      "${f}" "${job}" "${idx}" "${WANT}" "${first}" >&2
    failed=$((failed + 1))
  done < <(yq eval '.jobs | to_entries[] as $j | $j.value.steps | to_entries[] | select(.value.run != null and (.value.run | contains("\n"))) | $j.key + "|" + (.key | tostring)' "${f}")
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d multi-line run: block(s) missing strict-mode prelude\n' "${failed}" >&2
  exit 1
fi
exit 0
