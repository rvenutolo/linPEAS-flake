#!/usr/bin/env bash
# scripts/check-cron-table.sh
#
# @description Lint: cron schedule table in docs/architecture/ci.md
# matches cron triggers in .github/workflows/*.yml (and *.yaml) — set
# parity, cron string accuracy, and daily arrow-list ordering with
# strictly increasing UTC times.
#
# Exit codes:
#   0  all checks passed
#   1  drift detected (details printed to stderr)
#   2  missing input files / parse error / workflow declares >1 cron line

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "${_lib_dir}/lib/awk-path.sh"
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT

# Env overrides (test-only):
#   WORKFLOWS_DIR_OVERRIDE — alternate .github/workflows/ directory
#   DOC_FILE_OVERRIDE      — alternate docs/architecture/ci.md path
readonly WORKFLOWS_DIR="${WORKFLOWS_DIR_OVERRIDE:-${REPO_ROOT}/.github/workflows}"
readonly DOC_FILE="${DOC_FILE_OVERRIDE:-${REPO_ROOT}/docs/architecture/ci.md}"

# @description Emit `name<TAB>cron` for each workflow yaml with a cron schedule.
function workflow_pairs() {
  local f name cron
  local -a workflow_files=()
  glob_into workflow_files 'workflow YAML' \
    "${WORKFLOWS_DIR}/*.yml" "${WORKFLOWS_DIR}/*.yaml"
  # The `-f` gate stays: this scan holds files, and a directory named
  # `foo.yml` matches the pattern the same way a file does.
  for f in "${workflow_files[@]}"; do
    [[ -f ${f} ]] || continue
    name="$(basename "${f}")"
    name="${name%.yaml}"
    name="${name%.yml}"
    # defense-in-depth: the main() guard guarantees ≤1 cron line per file.
    cron="$(grep -E '^[[:space:]]*-[[:space:]]*cron:' "${f}" 2>/dev/null |
      head -1 |
      sed -E 's/.*cron:[[:space:]]*"([^"]+)".*/\1/')" || true
    [[ -n ${cron} ]] && printf '%s\t%s\n' "${name}" "${cron}"
  done
}

# @description Emit `name<TAB>cron` for each row in the ## Cron schedule table.
function table_pairs() {
  awk '
    /^## Cron schedule/ { in_section = 1; next }
    in_section && /^## / { in_section = 0 }
    in_section && /^\| `/ {
      if (match($0, /\| `([^`]+)` *\| `([^`]+)` */, m)) {
        printf "%s\t%s\n", m[1], m[2]
      }
    }
  ' "$(awk_path "${DOC_FILE}")"
}

# @description Emit `name<TAB>HH:MM` for each entry in the arrow list of the
#              "Daily crons fire in this UTC order: ..." paragraph.
function arrow_pairs() {
  awk '
    /Daily crons fire in this UTC order:/ {
      line = $0
      sub(/^.*UTC order: */, "", line)
      while (match(line, /`([^`]+)` *\(([0-9][0-9]:[0-9][0-9])\)/, m)) {
        printf "%s\t%s\n", m[1], m[2]
        line = substr(line, RSTART + RLENGTH)
      }
      exit
    }
  ' "$(awk_path "${DOC_FILE}")"
}

function main() {
  [[ -d ${WORKFLOWS_DIR} ]] || {
    printf 'missing %s\n' "${WORKFLOWS_DIR}" >&2
    exit 2
  }
  [[ -f ${DOC_FILE} ]] || {
    printf 'missing %s\n' "${DOC_FILE}" >&2
    exit 2
  }

  # A workflow with >1 cron line can't be represented in the name-keyed
  # table model; surface the limitation rather than silently dropping lines.
  local f cron_count
  local -a workflow_files=()
  glob_into workflow_files 'workflow YAML' \
    "${WORKFLOWS_DIR}/*.yml" "${WORKFLOWS_DIR}/*.yaml"
  # The `-f` gate stays: this scan holds files, and a directory named
  # `foo.yml` matches the pattern the same way a file does.
  for f in "${workflow_files[@]}"; do
    [[ -f ${f} ]] || continue
    cron_count="$(grep -Ec '^[[:space:]]*-[[:space:]]*cron:' "${f}" || true)"
    if ((cron_count > 1)); then
      printf 'multiple cron lines in %s (%d); not supported — extend check-cron-table.sh\n' \
        "${f}" "${cron_count}" >&2
      exit 2
    fi
  done

  local wf_tmp tbl_tmp arrow_tmp
  wf_tmp="$(make_temp)"
  tbl_tmp="$(make_temp)"
  arrow_tmp="$(make_temp)"
  # shellcheck disable=SC2064
  trap "rm --force -- '${wf_tmp}' '${tbl_tmp}' '${arrow_tmp}'" EXIT

  workflow_pairs | sort >"${wf_tmp}"
  table_pairs | sort >"${tbl_tmp}"

  [[ -s ${wf_tmp} ]] || {
    printf 'no cron lines found under %s\n' "${WORKFLOWS_DIR}" >&2
    exit 2
  }
  [[ -s ${tbl_tmp} ]] || {
    printf 'no rows parsed from %s\n' "${DOC_FILE}" >&2
    exit 2
  }

  local drift=0

  # --- Invariant 1: set parity ---
  # Names present on disk but absent from table.
  local missing_in_table
  missing_in_table="$(
    comm -23 <(cut -f1 "${wf_tmp}" | sort -u) <(cut -f1 "${tbl_tmp}" | sort -u)
  )"
  # Names present in table but absent on disk.
  local missing_on_disk
  missing_on_disk="$(
    comm -13 <(cut -f1 "${wf_tmp}" | sort -u) <(cut -f1 "${tbl_tmp}" | sort -u)
  )"
  # Same name, different cron string.
  local cron_mismatch
  cron_mismatch="$(
    join -t $'\t' -j 1 \
      <(sort -u "${wf_tmp}") \
      <(sort -u "${tbl_tmp}") |
      awk -F'\t' '$2 != $3 { printf "%s: workflow=%s table=%s\n", $1, $2, $3 }'
  )"

  if [[ -n ${missing_in_table} ]]; then
    printf 'missing-in-table:\n%s\n' "${missing_in_table}" >&2
    drift=1
  fi
  if [[ -n ${missing_on_disk} ]]; then
    printf 'missing-on-disk:\n%s\n' "${missing_on_disk}" >&2
    drift=1
  fi
  if [[ -n ${cron_mismatch} ]]; then
    printf 'cron-mismatch:\n%s\n' "${cron_mismatch}" >&2
    drift=1
  fi

  # --- Invariants 2 + 3: arrow list ---
  arrow_pairs >"${arrow_tmp}"
  if [[ ! -s ${arrow_tmp} ]]; then
    printf 'arrow-order: ordering paragraph not found or unparsable\n' >&2
    drift=1
  else
    # Expected: daily rows (cron M H * * *) sorted by HH:MM.
    local expected
    expected="$(
      table_pairs |
        awk -F'\t' '
          {
            n = split($2, p, " ")
            if (n >= 5 && p[3] == "*" && p[4] == "*" && p[5] == "*") {
              printf "%s\t%02d:%02d\n", $1, p[2], p[1]
            }
          }
        ' |
        sort -t $'\t' -k2,2
    )"

    if ! diff --unified <(printf '%s\n' "${expected}") "${arrow_tmp}" >/dev/null; then
      printf 'arrow-order: arrow list does not match daily rows (expected vs actual):\n' >&2
      diff --unified <(printf '%s\n' "${expected}") "${arrow_tmp}" >&2 || true
      drift=1
    fi

    local prev="" time
    while IFS=$'\t' read -r _name time; do
      if [[ -n ${prev} && ! ${time} > ${prev} ]]; then
        printf 'arrow-order: time %s not strictly after %s\n' "${time}" "${prev}" >&2
        drift=1
      fi
      prev="${time}"
    done <"${arrow_tmp}"
  fi

  if ((drift)); then exit 1; fi
  printf 'check-cron-table: ok (%d rows)\n' "$(wc -l <"${wf_tmp}")"
}

main "$@"
