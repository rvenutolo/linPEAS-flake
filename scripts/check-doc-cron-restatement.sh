#!/usr/bin/env bash
# scripts/check-doc-cron-restatement.sh
#
# @description Lint: ban restating literal workflow cron times in docs.
# A line that names a workflow (backticked bare name `NAME` or a
# `NAME.yml`/`NAME.yaml` token) AND carries a clock time (HH:MM) restates the
# single source of truth, the schedule table in docs/architecture/ci.md.
# Such lines must live only in that table; this lint flags them
# everywhere else (README.md + docs/**, excluding ci.md itself).
#
# Exit codes:
#   0  no restatements found
#   1  restatement(s) found (details printed to stderr)
#   2  missing/empty .github/workflows directory

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT

# Env overrides (test-only):
#   WORKFLOWS_DIR_OVERRIDE — alternate .github/workflows/ directory
#   SCAN_ROOT_OVERRIDE     — alternate root holding README.md + docs/ to scan
readonly WORKFLOWS_DIR="${WORKFLOWS_DIR_OVERRIDE:-${REPO_ROOT}/.github/workflows}"
readonly SCAN_ROOT="${SCAN_ROOT_OVERRIDE:-${REPO_ROOT}}"

# Clock-time pattern: HH:MM not embedded in a longer run of digits.
readonly TIME_RE='(^|[^0-9])[0-9]{1,2}:[0-9]{2}([^0-9]|$)'

# @description Emit the live workflow-name set: bare basename and the
#              `.yml`/`.yaml`-suffixed form, one per line.
function workflow_names() {
  local f base bare
  for f in "${WORKFLOWS_DIR}"/*.yml "${WORKFLOWS_DIR}"/*.yaml; do
    [[ -f ${f} ]] || continue
    base="$(basename "${f}")"
    bare="${base%.yaml}"
    bare="${bare%.yml}"
    printf '%s\n' "${bare}" "${base}"
  done
}

# @description Escape regex-significant characters in stdin for safe use
#              inside an ERE alternation.
function escape_ere() {
  sed -E 's/[][(){}.^$*+?|\\/]/\\&/g'
}

# @description List doc files to scan (README.md + docs/**.md), excluding
#              docs/architecture/ci.md, one path per line.
function scan_files() {
  [[ -f "${SCAN_ROOT}/README.md" ]] && printf '%s\n' "${SCAN_ROOT}/README.md"
  if [[ -d "${SCAN_ROOT}/docs" ]]; then
    find "${SCAN_ROOT}/docs" -type f -name '*.md' \
      ! -path "${SCAN_ROOT}/docs/architecture/ci.md" |
      sort
  fi
}

# @description Strip the README ci-summary block (BEGIN..END inclusive) so its
#              auto-generated restatements are exempt; pass other files through.
function readable_lines() {
  local -r file="$1"
  if [[ "$(basename "${file}")" == 'README.md' ]]; then
    awk '
      /<!-- BEGIN ci-summary -->/ { skip = 1 }
      !skip { print FNR "\t" $0 }
      /<!-- END ci-summary -->/   { skip = 0 }
    ' "${file}"
  else
    awk '{ print FNR "\t" $0 }' "${file}"
  fi
}

function main() {
  [[ -d ${WORKFLOWS_DIR} ]] || {
    printf 'missing %s\n' "${WORKFLOWS_DIR}" >&2
    exit 2
  }

  local names_tmp
  names_tmp="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm --force -- '${names_tmp}'" EXIT
  workflow_names | sort -u >"${names_tmp}"

  [[ -s ${names_tmp} ]] || {
    printf 'no workflow yaml files under %s\n' "${WORKFLOWS_DIR}" >&2
    exit 2
  }

  # Build an alternation of escaped names, then a name pattern that matches
  # either a backticked bare name (`NAME`) or a `.yml`/`.yaml`-suffixed
  # token. The suffixed form needs a left word boundary so a longer word
  # ending in a name (e.g. homepages.yml vs pages.yml) is not a false
  # positive; the backticked form is already delimited by its opening
  # backtick.
  local alt
  alt="$(escape_ere <"${names_tmp}" | paste -sd '|' -)"
  local name_re
  name_re="\`(${alt})\`|(^|[^[:alnum:]_-])(${alt})\\.(yml|yaml)"

  local found=0 file lineno text
  while IFS= read -r file; do
    [[ -n ${file} ]] || continue
    while IFS=$'\t' read -r lineno text; do
      if [[ ${text} =~ ${TIME_RE} ]] && [[ ${text} =~ ${name_re} ]]; then
        printf '%s:%s: %s\n' "${file}" "${lineno}" "${text}" >&2
        found=1
      fi
    done < <(readable_lines "${file}")
  done < <(scan_files)

  if ((found)); then exit 1; fi
  printf 'check-doc-cron-restatement: ok\n'
}

main "$@"
