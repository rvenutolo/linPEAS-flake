#!/usr/bin/env bash
# tests/check-runner-doc-diff.test.sh
#
# Accept/refuse matrix for scripts/check-runner-doc-diff.sh, the content
# floor a bot push of docs/architecture/ci.md or docs/install/nix.md must
# pass. Every scenario compares a copy of a live doc with an edited copy
# in its own scratch directory, so the checkout's docs are only read.
#
# The accepting rows matter as much as the refusing ones: a floor that
# refuses the generator's own re-padded output blocks every runner bump,
# so the re-pad rows feed it what scripts/refresh-runner-labels.sh writes
# for a wider label rather than a hand-built table.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-runner-doc-diff.sh"
readonly GENERATOR="${REPO_ROOT}/scripts/refresh-runner-labels.sh"
readonly LIVE_WORKFLOW="${REPO_ROOT}/.github/workflows/ci.yml"
readonly LIVE_CI_DOC="${REPO_ROOT}/docs/architecture/ci.md"
readonly LIVE_NIX_DOC="${REPO_ROOT}/docs/install/nix.md"
readonly CI_PATH='docs/architecture/ci.md'
readonly NIX_PATH='docs/install/nix.md'

failures=0
function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

work=''
function cleanup() {
  if [[ -n ${work} && -d ${work} ]]; then
    rm --recursive --force -- "${work}"
  fi
}
trap cleanup EXIT

# @description Create a scenario directory holding old.md and new.md,
# both copies of one live doc.
# @arg $1 scenario name  @arg $2 live doc
# @stdout the scenario directory
function new_case() {
  local -r dir="${work}/$1" live="$2"
  mkdir -- "${dir}"
  cp -- "${live}" "${dir}/old.md"
  cp -- "${live}" "${dir}/new.md"
  printf '%s' "${dir}"
}

# @description Run the floor and require an exit status and a stderr
# substring, recording the scenario for the discrimination gate.
# @arg $1 scenario name  @arg $2 scenario dir  @arg $3 wanted exit status
# @arg $4 wanted stderr substring  @arg $@ floor arguments
function expect() {
  local -r name="$1" dir="$2" want_rc="$3" text="$4"
  shift 4
  local rc=0
  "${SCRIPT}" "$@" >"${dir}/run.out" 2>"${dir}/run.err" || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${dir}/run.outcome"
  harness_assert_record "${name}" "${text}" "${dir}/run.outcome" "${dir}/run.out" "${dir}/run.err"
  if [[ ${rc} -eq ${want_rc} ]] && grep --fixed-strings --quiet -- "${text}" "${dir}/run.err"; then
    pass "${name}: exits ${want_rc} naming ${text}"
  else
    fail "${name}: exit ${rc}, want ${want_rc} and stderr holding '${text}'"
    sed 's/^/    /' -- "${dir}/run.err" >&2
  fi
}

# @description Print the line number of the first line matching a regex.
# @arg $1 file  @arg $2 extended regex
function line_of() {
  grep --line-number --extended-regexp --max-count=1 -- "$2" "$1" | cut --delimiter=: --fields=1
}

# @description Print the number of lines in the table whose header row
# starts at the given line.
# @arg $1 file  @arg $2 header line
function table_length() {
  awk -v start="$2" 'NR >= start { if ($0 ~ /^\|/) n++; else exit } END { print n + 0 }' "$1"
}

function main() {
  work="$(mktemp --directory)"
  local dir
  local -r tick=$'\x60'
  # Edits are written against the labels the live workflow carries today,
  # so a runner bump does not turn this harness red.
  local arm_label x86_label
  arm_label="$(yq '.jobs.build-linpeas-arm64.runs-on' "${LIVE_WORKFLOW}")"
  x86_label="$(yq '.jobs.build-linpeas.runs-on' "${LIVE_WORKFLOW}")"
  local -r wide_arm="${arm_label}-much-wider-label"
  # A label as wide as the live one, so swapping it in re-pads nothing.
  local same_width
  same_width="$(printf '%*s' "${#arm_label}" '' | tr ' ' 'x')"

  local ci_header ci_rows nix_header nix_rows arm_rows arm_line smoke_line nix_arm_line
  ci_header="$(line_of "${LIVE_CI_DOC}" '^\| Job +\| Runner +\| What it tests +\|$')"
  ci_rows="$(table_length "${LIVE_CI_DOC}" "${ci_header}")"
  nix_header="$(line_of "${LIVE_NIX_DOC}" '^\| System +\| Flake builds +\| CI tested +\|$')"
  nix_rows="$(table_length "${LIVE_NIX_DOC}" "${nix_header}")"
  arm_rows="$(grep --count --extended-regexp -- "^\\| ${tick}[^${tick}]*-arm64${tick} " "${LIVE_CI_DOC}")"
  arm_line="$(line_of "${LIVE_CI_DOC}" "^\\| ${tick}build-linpeas-arm64${tick} ")"
  smoke_line="$(line_of "${LIVE_CI_DOC}" "^\\| ${tick}smoke-test${tick} ")"
  nix_arm_line="$(line_of "${LIVE_NIX_DOC}" "^\\| ${tick}aarch64-linux${tick} ")"
  if [[ -z ${ci_header} || -z ${nix_header} || -z ${arm_line} || -z ${smoke_line} || -z ${nix_arm_line} ||
    ${arm_rows} -lt 1 ]]; then
    fail 'the live docs no longer hold the rows this harness edits'
    exit 1
  fi

  # identical-ok: an unchanged doc passes with nothing changed.
  dir="$(new_case identical-ok "${LIVE_CI_DOC}")"
  expect 'identical-ok' "${dir}" 0 "${CI_PATH}: 0 runner cell(s) changed, 0 table line(s) differ" \
    "${CI_PATH}" "${dir}/old.md" "${dir}/new.md"

  # runner-only-ok: a same-width label in every arm row.
  dir="$(new_case runner-only-ok "${LIVE_CI_DOC}")"
  sed --in-place "/^| ${tick}[^${tick}]*-arm64${tick} /s/${tick}${arm_label//./\\.}${tick}/${tick}${same_width}${tick}/" \
    "${dir}/new.md"
  expect 'runner-only-ok' "${dir}" 0 \
    "${CI_PATH}: ${arm_rows} runner cell(s) changed, ${arm_rows} table line(s) differ" \
    "${CI_PATH}" "${dir}/old.md" "${dir}/new.md"

  # repad-ok / nix-repad-ok: the generator's own output for a wider arm
  # label, which re-pads every line of both tables.
  dir="${work}/repad"
  mkdir -- "${dir}"
  cp -- "${LIVE_CI_DOC}" "${dir}/ci.md"
  cp -- "${LIVE_NIX_DOC}" "${dir}/nix.md"
  sed "s/runs-on: ${arm_label//./\\.}\$/runs-on: ${wide_arm}/" "${LIVE_WORKFLOW}" >"${dir}/ci.yml"
  if ! CI_WORKFLOW_OVERRIDE="${dir}/ci.yml" CI_DOC_OVERRIDE="${dir}/ci.md" NIX_DOC_OVERRIDE="${dir}/nix.md" \
    "${GENERATOR}" 2>"${dir}/gen.err"; then
    fail 'repad: the generator failed on a wider arm label'
    sed 's/^/    /' -- "${dir}/gen.err" >&2
  fi
  mkdir -- "${dir}/ci" "${dir}/nix"
  expect 'repad-ok' "${dir}/ci" 0 \
    "${CI_PATH}: ${arm_rows} runner cell(s) changed, ${ci_rows} table line(s) differ" \
    "${CI_PATH}" "${LIVE_CI_DOC}" "${dir}/ci.md"
  expect 'nix-repad-ok' "${dir}/nix" 0 \
    "${NIX_PATH}: 1 runner cell(s) changed, ${nix_rows} table line(s) differ" \
    "${NIX_PATH}" "${LIVE_NIX_DOC}" "${dir}/nix.md"

  # prose-edit-refused: a description cell changes.
  dir="$(new_case prose-edit-refused "${LIVE_CI_DOC}")"
  sed --in-place "${arm_line}s/aarch64 build of/aarch64 build, PAYLOAD_RAN, of/" "${dir}/new.md"
  expect 'prose-edit-refused' "${dir}" 1 "${CI_PATH}:${arm_line}: cell 3 (What it tests) changed" \
    "${CI_PATH}" "${dir}/old.md" "${dir}/new.md"

  # nix-prose-edit-refused: a Flake builds cell changes, width kept.
  dir="$(new_case nix-prose-edit-refused "${LIVE_NIX_DOC}")"
  sed --in-place "${nix_arm_line}s/| yes  /| no   /" "${dir}/new.md"
  expect 'nix-prose-edit-refused' "${dir}" 1 "${NIX_PATH}:${nix_arm_line}: cell 2 (Flake builds) changed" \
    "${NIX_PATH}" "${dir}/old.md" "${dir}/new.md"

  # line-added-refused: one line inserted right after the table.
  dir="$(new_case line-added-refused "${LIVE_NIX_DOC}")"
  local -r after_nix=$((nix_header + nix_rows))
  sed --in-place "$((after_nix - 1))a PAYLOAD_RAN" "${dir}/new.md"
  local old_count
  old_count="$(wc --lines <"${LIVE_NIX_DOC}")"
  expect 'line-added-refused' "${dir}" 1 \
    "${NIX_PATH}:${after_nix}: line count changed (old ${old_count} lines, new $((old_count + 1)))" \
    "${NIX_PATH}" "${dir}/old.md" "${dir}/new.md"

  # outside-table-refused: the line above the blank before the header.
  dir="$(new_case outside-table-refused "${LIVE_CI_DOC}")"
  local -r above=$((ci_header - 2))
  sed --in-place "${above}s/\$/ PAYLOAD_RAN/" "${dir}/new.md"
  expect 'outside-table-refused' "${dir}" 1 "${CI_PATH}:${above}: line outside the table changed" \
    "${CI_PATH}" "${dir}/old.md" "${dir}/new.md"

  # runner-cell-garbage-refused: a runner cell gains text after its label.
  dir="$(new_case runner-cell-garbage-refused "${LIVE_CI_DOC}")"
  sed --in-place "${smoke_line}s/| ${tick}${x86_label}${tick}/| ${tick}x${tick} and more/" "${dir}/new.md"
  expect 'runner-cell-garbage-refused' "${dir}" 1 \
    "${CI_PATH}:${smoke_line}: the new runner cell is not one backticked label" \
    "${CI_PATH}" "${dir}/old.md" "${dir}/new.md"

  # old-runner-cell-odd-refused: both sides of a changed runner cell must
  # hold a label, so a branch blob whose cell holds more is not rewritten.
  dir="$(new_case old-runner-cell-odd-refused "${LIVE_CI_DOC}")"
  sed --in-place "${smoke_line}s/| ${tick}${x86_label}${tick}/| ${tick}x${tick} and more/" "${dir}/old.md"
  expect 'old-runner-cell-odd-refused' "${dir}" 1 \
    "${CI_PATH}:${smoke_line}: the old runner cell is not one backticked label" \
    "${CI_PATH}" "${dir}/old.md" "${dir}/new.md"

  # nix-runner-shape-refused: the CI tested cell drops its yes (...).
  dir="$(new_case nix-runner-shape-refused "${LIVE_NIX_DOC}")"
  sed --in-place "${nix_arm_line}s/yes (${tick}${arm_label//./\\.}${tick})/${tick}${arm_label//./\\.}${tick}/" \
    "${dir}/new.md"
  expect 'nix-runner-shape-refused' "${dir}" 1 \
    "${NIX_PATH}:${nix_arm_line}: the new runner cell is not yes (" \
    "${NIX_PATH}" "${dir}/old.md" "${dir}/new.md"

  # separator-refused: an alignment colon in the separator row.
  dir="$(new_case separator-refused "${LIVE_CI_DOC}")"
  sed --in-place "$((ci_header + 1))s/^| -/| :/" "${dir}/new.md"
  expect 'separator-refused' "${dir}" 1 \
    "${CI_PATH}:$((ci_header + 1)): separator cell 1 is not a run of dashes" \
    "${CI_PATH}" "${dir}/old.md" "${dir}/new.md"

  # extra-cell-refused: a body row gains a cell.
  dir="$(new_case extra-cell-refused "${LIVE_CI_DOC}")"
  sed --in-place "${smoke_line}s/\$/ extra |/" "${dir}/new.md"
  expect 'extra-cell-refused' "${dir}" 1 "${CI_PATH}:${smoke_line}: the new row has 4 cells; the header has 3" \
    "${CI_PATH}" "${dir}/old.md" "${dir}/new.md"

  # control-a-refused: the byte the cell split reserves for an escaped
  # pipe, inside a table row.
  dir="$(new_case control-a-refused "${LIVE_CI_DOC}")"
  sed --in-place "${arm_line}s/aarch64 build/aarch64\x01build/" "${dir}/new.md"
  expect 'control-a-refused' "${dir}" 1 "${CI_PATH}:${arm_line}: the table line holds a control-A byte" \
    "${CI_PATH}" "${dir}/old.md" "${dir}/new.md"

  # final-newline-refused: same lines, the last newline dropped.
  dir="$(new_case final-newline-refused "${LIVE_NIX_DOC}")"
  head --bytes=-1 -- "${LIVE_NIX_DOC}" >"${dir}/new.md"
  expect 'final-newline-refused' "${dir}" 1 \
    "${NIX_PATH}:${old_count}: the final newline was added or removed" \
    "${NIX_PATH}" "${dir}/old.md" "${dir}/new.md"

  # header-missing-refused: neither side holds the header row.
  dir="$(new_case header-missing-refused "${LIVE_CI_DOC}")"
  sed --in-place "${ci_header}s/| Runner /| Runners/" "${dir}/old.md" "${dir}/new.md"
  expect 'header-missing-refused' "${dir}" 1 \
    "${CI_PATH}: old file: no table with the header row | Job | Runner | What it tests |" \
    "${CI_PATH}" "${dir}/old.md" "${dir}/new.md"

  # header-twice-refused: the header row appears again further down.
  dir="$(new_case header-twice-refused "${LIVE_CI_DOC}")"
  printf '\n' >>"${dir}/old.md"
  sed --quiet "${ci_header},$((ci_header + 1))p" -- "${LIVE_CI_DOC}" >>"${dir}/old.md"
  cp -- "${dir}/old.md" "${dir}/new.md"
  local -r second_header=$(($(wc --lines <"${LIVE_CI_DOC}") + 2))
  expect 'header-twice-refused' "${dir}" 1 \
    "${CI_PATH}:${second_header}: old file: the header row appears again" \
    "${CI_PATH}" "${dir}/old.md" "${dir}/new.md"

  # doc-path-mismatch-refused: the doc path picks the header, so ci.md
  # content checked as nix.md finds no table.
  dir="$(new_case doc-path-mismatch-refused "${LIVE_CI_DOC}")"
  expect 'doc-path-mismatch-refused' "${dir}" 1 \
    "${NIX_PATH}: old file: no table with the header row | System | Flake builds | CI tested |" \
    "${NIX_PATH}" "${dir}/old.md" "${dir}/new.md"

  # Could-not-run conditions exit 2.
  dir="$(new_case unknown-doc-path "${LIVE_CI_DOC}")"
  expect 'unknown-doc-path' "${dir}" 2 'unknown doc path: docs/README.md' \
    'docs/README.md' "${dir}/old.md" "${dir}/new.md"

  dir="$(new_case missing-file "${LIVE_CI_DOC}")"
  expect 'missing-file' "${dir}" 2 "${dir}/absent.md: not a readable file" \
    "${CI_PATH}" "${dir}/old.md" "${dir}/absent.md"

  dir="$(new_case wrong-arg-count "${LIVE_CI_DOC}")"
  expect 'wrong-arg-count' "${dir}" 2 'usage: check-runner-doc-diff.sh <doc-path> <old-file> <new-file>' \
    "${CI_PATH}" "${dir}/old.md"

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '%d failure(s)\n' "${failures}" >&2
    exit 1
  fi
  printf 'all passed\n'
}

main "$@"
