#!/usr/bin/env bash
# tests/check-doc-anchors.test.sh

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# The harness rewrites generated docs and fixture modes, so it runs in a
# scratch copy of the tree and leaves this checkout untouched.
# shellcheck source=scripts/lib/scratch-tree.sh
source "${REPO_ROOT}/scripts/lib/scratch-tree.sh"
reexec_in_scratch_tree "$@"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
# shellcheck source=scripts/lib/locale-gap.sh
source "${REPO_ROOT}/scripts/lib/locale-gap.sh"
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
# @arg $7 locale (empty: inherit)
function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r source_rel="$3"
  local -r expected_exit="$4"
  local -r expected_stderr="$5"
  local -r expected_stdout="${6:-}"
  local -r locale="${7:-}"

  local root="${FIXTURES}/${fixture_dir}"
  if [[ ${fixture_dir} == /* ]]; then
    root="${fixture_dir}"
  fi

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local -a env_prefix=()
  if [[ -n ${locale} ]]; then
    env_prefix=(env "LC_ALL=${locale}")
  fi
  local actual_exit=0
  DOC_ANCHOR_ROOT_OVERRIDE="${root}" \
    DOC_ANCHOR_SOURCES_OVERRIDE="${source_rel}" \
    ${env_prefix[@]+"${env_prefix[@]}"} "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
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

# @description Build a doc-anchors root holding source.md (one link to
# docs/target.md#<anchor>) and docs/target.md (<target body>). Prints the
# root.
# @arg $1 anchor  @arg $2 target body
function scratch_anchor_root() {
  local root
  root="$(mktemp --directory)"
  mkdir --parents "${root}/docs"
  printf '# Source\n\nSee [x](docs/target.md#%s).\n' "$1" >"${root}/source.md"
  printf '%s\n' "$2" >"${root}/docs/target.md"
  printf '%s\n' "${root}"
}

# @description Build a PATH dir whose `awk` fails the Nth call that passes
# `blank=0` and names a `docs/target.md`, and runs the real awk otherwise.
# A POSIX sh shim: a bash one would source BASH_ENV, whose profile runs
# awk, and recurse into itself. Prints the dir.
# @arg $1 N
function target_awk_shim() {
  local dir
  dir="$(mktemp --directory)"
  printf '0\n' >"${dir}/count"
  # shellcheck disable=SC2016 # the shim body expands when the shim runs, not here
  printf '#!/bin/sh\nz=0; t=0\nfor a in "$@"; do\n  [ "$a" = blank=0 ] && z=1\n  case "$a" in */docs/target.md) t=1 ;; esac\ndone\nif [ "$z" = 1 ] && [ "$t" = 1 ]; then\n  n=$(($(cat %s) + 1))\n  printf "%%s\\n" "$n" >%s\n  [ "$n" = %s ] && exit 2\nfi\nexec %s "$@"\n' \
    "${dir}/count" "${dir}/count" "$1" "$(command -v awk)" >"${dir}/awk"
  chmod 755 -- "${dir}/awk"
  printf '%s\n' "${dir}"
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

  # A docs/ filename holding a newline is one path, and `enumerate_into`
  # carries it through the scan as one array element, so the broken anchor
  # inside it is found and reported like any other file's — alongside an
  # unrelated README.md that keeps the run's tallies nonzero regardless.
  # Built at runtime rather than checked in because treefmt walks
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

  # The two renderers slug a non-ASCII letter differently (GitHub keeps
  # it, mkdocs folds it to ASCII), so no link can resolve on both and the
  # heading must carry an explicit anchor. en_US.UTF-8 is where the slug
  # sed would otherwise keep `é` and vouch for the GitHub-only link.
  require_grep_locale_gap en_US.UTF-8 || exit 1
  require_sed_locale_gap en_US.UTF-8 || exit 1
  local root
  root="$(scratch_anchor_root 'café' $'# Target\n\n## Café\n\nBody.')"
  run_scenario 'non-ASCII letter heading without an anchor fails under en_US.UTF-8' \
    "${root}" $'source.md\ndocs/target.md' 1 \
    '[non-ascii-heading] docs/target.md:3: heading "Café" holds a non-ASCII letter' \
    '' en_US.UTF-8
  rm --recursive --force -- "${root}"

  # Anchored, the heading is a valid target and still counts as lossy: the
  # lossy-count grep runs under C, so it sees the `é` as a deleted
  # character in en_US.UTF-8 too.
  root="$(scratch_anchor_root 'cafe' $'# Target\n\n## Café<a name="cafe"></a>\n\n## Plain\n\nBody.')"
  run_scenario 'anchored non-ASCII heading counts as lossy under en_US.UTF-8' \
    "${root}" $'source.md\ndocs/target.md' 0 '' \
    'ok — 1 anchor link(s) in 2 source file(s) resolved against 3 anchor(s) in 1 target file(s); 1 heading(s) required character deletion' \
    en_US.UTF-8
  rm --recursive --force -- "${root}"

  # A link spelled as GitHub slugs the anchored heading (the letter kept)
  # misses, since only the explicit anchor answers. This is the
  # GitHub-spelled counterpart of the scenario below, whose link is the
  # C-locale slug with the letter deleted.
  root="$(scratch_anchor_root 'naïve' $'# Target\n\n## Naïve<a name="naive"></a>\n\nBody.')"
  run_scenario 'GitHub-only non-ASCII anchor link is a miss under en_US.UTF-8' \
    "${root}" $'source.md\ndocs/target.md' 1 \
    '[anchor-miss] source.md:3: #naïve not found in docs/target.md' \
    '' en_US.UTF-8
  rm --recursive --force -- "${root}"

  # The generated slug of an anchored non-ASCII heading (`rsum`) resolves
  # on neither renderer, so it is not a target: only the explicit anchor
  # is.
  root="$(scratch_anchor_root 'rsum' $'# Target\n\n## Résumé<a name="resume"></a>\n\nBody.')"
  run_scenario 'generated slug of an anchored non-ASCII heading is a miss under en_US.UTF-8' \
    "${root}" $'source.md\ndocs/target.md' 1 \
    '[anchor-miss] source.md:3: #rsum not found in docs/target.md (available: target,resume)' \
    '' en_US.UTF-8
  rm --recursive --force -- "${root}"

  # Non-ASCII punctuation is deleted by both renderers, so it needs no
  # anchor.
  root="$(scratch_anchor_root 'build--release' $'# Target\n\n## Build — release\n\nBody.')"
  run_scenario 'non-ASCII punctuation heading passes under en_US.UTF-8' \
    "${root}" $'source.md\ndocs/target.md' 0 '' \
    'ok — 1 anchor link(s) in 2 source file(s) resolved against 2 anchor(s) in 1 target file(s); 1 heading(s) required character deletion' \
    en_US.UTF-8
  rm --recursive --force -- "${root}"

  # A heading inside a fenced block is not a heading.
  root="$(scratch_anchor_root 'target' $'# Target\n\n```text\n## Café\n```')"
  run_scenario 'non-ASCII letter heading inside a fence passes under en_US.UTF-8' \
    "${root}" $'source.md\ndocs/target.md' 0 '' \
    'ok — 1 anchor link(s) in 2 source file(s) resolved against 1 anchor(s) in 1 target file(s); 0 heading(s) required character deletion' \
    en_US.UTF-8
  rm --recursive --force -- "${root}"

  # The non-ASCII heading check rests on grep reading UTF-8 under
  # --perl-regexp. Where it cannot, the check matches nothing, so the run
  # must refuse rather than pass.
  local shim_dir real_grep
  shim_dir="$(mktemp --directory)"
  real_grep="$(command -v grep)"
  # shellcheck disable=SC2016 # the shim body expands when the shim runs, not here
  printf '#!%s\nfor a in "$@"; do [[ $a == --perl-regexp ]] && exit 1; done\nexec %q "$@"\n' \
    "$(command -v bash)" "${real_grep}" >"${shim_dir}/grep"
  chmod 755 -- "${shim_dir}/grep"
  root="$(scratch_anchor_root 'other' $'# Target\n\n## Other\n\nBody.')"
  PATH="${shim_dir}:${PATH}" run_scenario 'grep without UTF-8 PCRE is a could-not-run' \
    "${root}" $'source.md\ndocs/target.md' 2 \
    'grep --perl-regexp under C.UTF-8 does not read é as a letter'
  rm --recursive --force -- "${root}" "${shim_dir}"

  # A NUL byte makes grep call the text binary and print a notice instead
  # of its links, and a bash variable drops it, so a NUL-bearing file is
  # refused. The clean second source keeps the run's link tally nonzero:
  # without it the empty-scan floor, not the refusal, ends the run.
  root="$(scratch_anchor_root 'target' $'# Target\n\nBody.')"
  printf '# Source\n\nSee [x](docs/target.md#missing).\n\0\n' >"${root}/source.md"
  printf 'See [y](docs/target.md#target).\n' >"${root}/other.md"
  run_scenario 'NUL byte in a source is a could-not-run' \
    "${root}" $'source.md\nother.md' 2 \
    'refusing source.md: it holds a NUL byte'
  rm --recursive --force -- "${root}"

  # A NUL-bearing link target is refused too, before its headings are read.
  root="$(scratch_anchor_root 'target' $'# Target\n\nBody.')"
  printf '# Target\n\0\n' >"${root}/docs/target.md"
  run_scenario 'NUL byte in a link target is a could-not-run' \
    "${root}" 'source.md' 2 \
    'refusing docs/target.md: it holds a NUL byte'
  rm --recursive --force -- "${root}"

  # A target nothing can read must end the run, not read as a target
  # with no headings and report every link into it as a miss.
  root="$(scratch_anchor_root 'target' $'# Target\n\nBody.')"
  chmod 000 -- "${root}/docs/target.md"
  run_scenario 'unreadable link target is a could-not-run' \
    "${root}" 'source.md' 2 \
    'could not read docs/target.md to check it for a NUL byte'
  chmod 644 -- "${root}/docs/target.md"
  rm --recursive --force -- "${root}"

  # An awk failure on a target that grep can read: the heading read and
  # the lossy count each run awk on the target with `blank=0`, in that
  # order, so the shim fails the Nth such call alone.
  local target_shim_dir
  target_shim_dir="$(target_awk_shim 1)"
  root="$(scratch_anchor_root 'target' $'# Target\n\nBody.')"
  PATH="${target_shim_dir}:${PATH}" run_scenario 'awk failure reading target headings is a could-not-run' \
    "${root}" 'source.md' 2 \
    'could not read docs/target.md for headings'
  rm --recursive --force -- "${root}" "${target_shim_dir}"
  target_shim_dir="$(target_awk_shim 2)"
  root="$(scratch_anchor_root 'target' $'# Target\n\nBody.')"
  PATH="${target_shim_dir}:${PATH}" run_scenario 'awk failure counting lossy target headings is a could-not-run' \
    "${root}" 'source.md' 2 \
    'could not read docs/target.md for its lossy-heading count'
  rm --recursive --force -- "${root}" "${target_shim_dir}"

  # An awk read failure while collecting headings must end the run, not
  # read as "no headings". Only the blank-mode call of without_fences
  # passes `blank=1`, so the shim breaks that call alone.
  local awk_shim_dir real_awk
  awk_shim_dir="$(mktemp --directory)"
  real_awk="$(command -v awk)"
  # A POSIX sh shim: a bash one would source BASH_ENV, whose profile runs
  # awk, and recurse into itself.
  # shellcheck disable=SC2016 # the shim body expands when the shim runs, not here
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = blank=1 ] && exit 2; done\nexec %s "$@"\n' \
    "${real_awk}" >"${awk_shim_dir}/awk"
  chmod 755 -- "${awk_shim_dir}/awk"
  root="$(scratch_anchor_root 'other' $'# Target\n\n## Other\n\nBody.')"
  PATH="${awk_shim_dir}:${PATH}" run_scenario 'awk failure reading headings is a could-not-run' \
    "${root}" $'source.md\ndocs/target.md' 2 \
    'could not read source.md for headings'
  rm --recursive --force -- "${root}" "${awk_shim_dir}"

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
