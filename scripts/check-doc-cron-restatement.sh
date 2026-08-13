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
#   2  the check could not run: missing/empty .github/workflows directory,
#      or a producer that lists or reads the doc files failed

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/enumerate.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/enumerate.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT

# Env overrides (test-only):
#   WORKFLOWS_DIR_OVERRIDE — alternate .github/workflows/ directory
#   SCAN_ROOT_OVERRIDE     — alternate root holding README.md + docs/ to scan
readonly WORKFLOWS_DIR="${WORKFLOWS_DIR_OVERRIDE:-${REPO_ROOT}/.github/workflows}"
readonly SCAN_ROOT="${SCAN_ROOT_OVERRIDE:-${REPO_ROOT}}"

# Clock-time pattern: HH:MM not embedded in a longer run of digits.
readonly TIME_RE='(^|[^0-9])[0-9]{1,2}:[0-9]{2}([^0-9]|$)'

# @description Emit the live workflow file paths (`*.yml`, `*.yaml`), one per
#              line. Kept separate from the name set so the summary can report
#              how many workflows the scan was held against, rather than the
#              larger count of name forms each one contributes.
function workflow_files() {
  local f
  for f in "${WORKFLOWS_DIR}"/*.yml "${WORKFLOWS_DIR}"/*.yaml; do
    [[ -f ${f} ]] || continue
    printf '%s\n' "${f}"
  done
}

# @description Emit the live workflow-name set: bare basename and the
#              `.yml`/`.yaml`-suffixed form, one per line.
# @arg $@ workflow file paths
function workflow_names() {
  local f base bare
  for f in "$@"; do
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

# @description Emit every docs/**/*.md path under SCAN_ROOT, excluding
#              docs/architecture/ci.md, NUL-delimited and sorted.
# shellcheck disable=SC2329 # invoked indirectly, by name, via enumerate_into
function doc_cron_docs_scan() {
  find "${SCAN_ROOT}/docs" -type f -name '*.md' \
    ! -path "${SCAN_ROOT}/docs/architecture/ci.md" -print0 |
    sort --zero-terminated
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

  local wf_out
  if ! wf_out="$(workflow_files)"; then
    printf 'doc-cron-restatement: workflow_files failed\n' >&2
    exit 2
  fi
  local -a wf_paths=()
  # A newline-delimited handoff (rather than an array threaded straight
  # from `workflow_files`) is safe here: at the default WORKFLOWS_DIR, every
  # path this glob can emit is a tracked `.github/workflows/*.yml`|`*.yaml`
  # file, and `check-path-hygiene.sh` rejects any tracked path containing a
  # control character; under WORKFLOWS_DIR_OVERRIDE (test-only, and never
  # itself git-tracked) every fixture names its workflow with a plain ASCII
  # literal, so no caller of this handoff constructs a newline-bearing name.
  if [[ -n ${wf_out} ]]; then
    mapfile -t wf_paths <<<"${wf_out}"
  fi
  workflow_names ${wf_paths[@]+"${wf_paths[@]}"} | sort -u >"${names_tmp}"

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

  local found=0 file lineno text lines_out
  # Scope tallies for the summary line. `timed` counts the lines that reached
  # the workflow-name test at all: a clean verdict over zero timed lines
  # proves nothing about the name test, so an operator wants the two apart.
  # `readme_skipped` is the evidence behind the ci-summary exemption.
  local -i docs=0 lines=0 timed=0 kept=0 readme_total=0 readme_skipped=0

  # The file list is built by appending arrays, never by joining paths into
  # a newline-delimited string and re-splitting it: a docs/ path carrying
  # an embedded newline survives `enumerate_into` as one array element, and
  # a join-then-`read`-split round trip would fracture it right back into
  # two nonexistent paths. LINT_ALLOW_EMPTY_SCAN is forced on the docs/
  # call alone because a repo may legitimately carry README.md as its only
  # scanned doc and no docs/ tree at all.
  local -a files=()
  if [[ -f "${SCAN_ROOT}/README.md" ]]; then
    files+=("${SCAN_ROOT}/README.md")
  fi
  if [[ -d "${SCAN_ROOT}/docs" ]]; then
    local -a docs_files=()
    LINT_ALLOW_EMPTY_SCAN=1 enumerate_into docs_files 'find docs' doc_cron_docs_scan
    files+=(${docs_files+"${docs_files[@]}"})
  fi

  for file in ${files+"${files[@]}"}; do
    # `readable_lines` does have a reachable failure: a doc path awk
    # cannot open (permissions, a dangling symlink) is a tooling fault, not
    # a clean file.
    if ! lines_out="$(readable_lines "${file}")"; then
      printf 'doc-cron-restatement: readable_lines failed for %s\n' "${file}" >&2
      exit 2
    fi
    # A file the producer emitted nothing for yields one empty record here,
    # which carries no line number and so is not a line to score.
    kept=0
    while IFS=$'\t' read -r lineno text; do
      [[ -n ${lineno} ]] || continue
      kept=$((kept + 1))
      if [[ ${text} =~ ${TIME_RE} ]]; then
        timed=$((timed + 1))
        if [[ ${text} =~ ${name_re} ]]; then
          printf '%s:%s: %s\n' "${file}" "${lineno}" "${text}" >&2
          found=1
        fi
      fi
    done <<<"${lines_out}"
    docs=$((docs + 1))
    lines=$((lines + kept))
    if [[ "$(basename "${file}")" == 'README.md' ]]; then
      # Same producer class as `readable_lines`, so the same fault applies:
      # a path awk cannot open must be loud, not scored as a zero-line file.
      if ! readme_total="$(awk 'END { print FNR }' "${file}")"; then
        printf 'doc-cron-restatement: line count failed for %s\n' "${file}" >&2
        exit 2
      fi
      readme_skipped=$((readme_skipped + readme_total - kept))
    fi
  done

  if ((found)); then exit 1; fi

  # Name the exemptions that fired, with the evidence behind each: both of
  # them silently drop input, so a clean verdict that rested on one is only
  # auditable if the run says so.
  local -a exemptions=()
  if [[ -f "${SCAN_ROOT}/docs/architecture/ci.md" ]]; then
    exemptions+=('docs/architecture/ci.md excluded')
  fi
  if ((readme_skipped > 0)); then
    exemptions+=("README ci-summary block (${readme_skipped} line(s) skipped)")
  fi
  local exempt_desc='none' e
  for e in ${exemptions[@]+"${exemptions[@]}"}; do
    if [[ ${exempt_desc} == 'none' ]]; then
      exempt_desc="${e}"
    else
      exempt_desc="${exempt_desc}, ${e}"
    fi
  done

  printf 'check-doc-cron-restatement: ok — scanned %d doc(s), %d line(s) against %d workflow(s); %d line(s) carried a clock time; exemptions applied: %s\n' \
    "${docs}" "${lines}" "${#wf_paths[@]}" "${timed}" "${exempt_desc}"
}

main "$@"
