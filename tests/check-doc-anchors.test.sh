#!/usr/bin/env bash
# tests/check-doc-anchors.test.sh

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-doc-anchors.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-doc-anchors"

failures=0

# @description Run the lint over a fixture root; assert exit code, stderr, and
# — on the clean path — the summary line naming what was resolved. The tally
# of slugs that lost characters is what separates the clean scenarios: they
# exercise different arms of the slug algorithm, and every one of them
# otherwise ends in the same silent success.
#
# An absolute path in $2 is used as the root as given, so a scenario can
# drive a scratch tree that no fixture directory could hold. An empty $3
# leaves DOC_ANCHOR_SOURCES_OVERRIDE unset, which is what puts the lint's
# own source enumeration — rather than a handed-in list — under test.
# @arg $1 name  @arg $2 fixture dir or absolute root  @arg $3 source rel path
# @arg $4 expected exit  @arg $5 stderr substring  @arg $6 stdout substring
function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r source_rel="$3"
  local -r expected_exit="$4"
  local -r expected_stderr="$5"
  local -r expected_stdout="${6:-}"

  local root="${FIXTURES}/${fixture_dir}"
  if [[ ${fixture_dir} == /* ]]; then
    root="${fixture_dir}"
  fi

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  DOC_ANCHOR_ROOT_OVERRIDE="${root}" \
    DOC_ANCHOR_SOURCES_OVERRIDE="${source_rel}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stdout} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stdout}" "${stdout_file}"; then
    printf 'FAIL: %s — stdout missing %q\n' "${name}" "${expected_stdout}" >&2
    cat -- "${stdout_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  if [[ -n ${expected_stdout} ]]; then
    harness_assert_also "${expected_stdout}"
  fi
  rm --force -- "${outcome_file}" "${stdout_file}" "${stderr_file}"
}

function main() {
  # Two links, one cross-file and one same-file, so two target files are
  # resolved and neither heading loses a character to slugging.
  run_scenario 'good links pass' 'good' 'source.md' 0 '' \
    'ok — 2 anchor link(s) in 1 source file(s) resolved against 3 anchor(s) in 2 target file(s); 0 heading(s) required character deletion'
  run_scenario 'cross-file anchor miss fails' \
    'bad-anchor-miss' 'source.md' 1 \
    '[anchor-miss] source.md:3: #nonexistent-section not found in docs/target.md'
  run_scenario 'same-file anchor miss fails' \
    'bad-same-file' 'source.md' 1 \
    '[anchor-miss] source.md:3: #missing-anchor not found in source.md'
  run_scenario 'broken first link among multiple on one line fails' \
    'bad-multi-link' 'source.md' 1 \
    '[anchor-miss] source.md:3: #nonexistent not found in docs/target.md (available: good-heading)'
  run_scenario 'heading inside a code fence is not a slug source' \
    'bad-fenced-heading' 'source.md' 1 \
    '[anchor-miss] source.md:3: #fenced-phantom not found in docs/target.md (available: fence-target)'
  # `_` survives the delete step, so no heading is counted lossy.
  run_scenario 'underscore is preserved in the slug' \
    'good-underscore' 'source.md' 0 '' \
    'ok — 1 anchor link(s) in 1 source file(s) resolved against 2 anchor(s) in 1 target file(s); 0 heading(s) required character deletion'
  # The apostrophe is deleted, so exactly one of the target's two headings
  # slugs lossily — the arm where GFM and mkdocs-material can disagree.
  run_scenario 'apostrophe is deleted from the slug' \
    'good-apostrophe' 'source.md' 0 '' \
    'ok — 1 anchor link(s) in 1 source file(s) resolved against 2 anchor(s) in 1 target file(s); 1 heading(s) required character deletion'

  # The fixture carries only the stranded link, so nothing else in the run
  # could account for the failure. A link whose target .md is missing is
  # skipped before it is counted, so the tally moves no more than the
  # verdict does and the strand is invisible either way.
  run_scenario 'link to a missing target file fails' \
    'bad-stranded-link' 'source.md' 1 \
    '[stranded-link] source.md:7: docs/renamed-away.md#some-section links to docs/renamed-away.md, which does not exist'

  # The default source enumeration, pointed at a root with no docs tree and
  # no README. The clean scenarios above all end in the same `ok` line, and
  # so does a run that read nothing, so the floor is on the tallies that
  # line reports rather than on the enumeration alone.
  local empty_root
  empty_root="$(mktemp --directory)"
  run_scenario 'root with no sources is a could-not-run' \
    "${empty_root}" '' 2 \
    'scanned 0 source file(s)'
  rm --recursive --force -- "${empty_root}"

  # Sources the run did read, none of which carries an anchor link. Same
  # zero breadth, different cause, so the diagnostic names the other tally.
  run_scenario 'sources with no anchor link are a could-not-run' \
    'no-anchor-links' 'source.md' 2 \
    'checked 0 anchor link(s) across 1 source file(s)'

  # A source the enumeration listed but grep could not read. grep exits 2
  # there; scored as "no anchor links in this file" it leaves the file
  # counted in sources_scanned and every link in it unchecked.
  local unreadable_src="${FIXTURES}/unreadable-source/source.md"
  chmod 000 -- "${unreadable_src}"
  run_scenario 'unreadable source is a could-not-run' \
    'unreadable-source' 'source.md' 2 \
    'grep failed reading source.md for anchor links'
  chmod 644 -- "${unreadable_src}"

  # A docs/ filename holding a newline splits across `find`'s
  # newline-delimited handoff into two paths that neither resolve to a real
  # file, so the doc — and the broken anchor link inside it — goes
  # unscanned while an unrelated README.md keeps the run's tallies
  # nonzero. Built at runtime rather than checked in because treefmt walks
  # tests/fixtures and its exclude list cannot express a path containing a
  # newline.
  local newline_root
  newline_root="$(mktemp --directory)"
  mkdir --parents "${newline_root}/docs"
  printf '# Readme\n\nSee [x](#readme).\n' >"${newline_root}/README.md"
  printf '[broken](#does-not-exist)\n' \
    >"${newline_root}/docs/$(printf 'evil\ndoc').md"
  run_scenario 'newline-doc-name' \
    "${newline_root}" '' 1 \
    '[anchor-miss] docs/evil'
  rm --recursive --force -- "${newline_root}"

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
