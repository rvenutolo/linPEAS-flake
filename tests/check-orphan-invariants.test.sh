#!/usr/bin/env bash
# tests/check-orphan-invariants.test.sh

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
# shellcheck source=scripts/lib/locale-gap.sh
source "${REPO_ROOT}/scripts/lib/locale-gap.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-orphan-invariants.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-orphan-invariants"

failures=0

function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"
  local -r locale="${5:-}"

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
  INVARIANT_INDEX_OVERRIDE="${root}/index.md" \
    DOCS_ROOT_OVERRIDE="${root}/docs" \
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
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
}

# Build an index holding one in-class pointer to an existing doc and the
# given extra link, then run the lint against it. An optional docs-relative
# path is created as a doc.
function run_off_class_scenario() {
  local -r name="$1"
  local -r link="$2"
  local -r extra_doc="$3"
  local -r expected_stderr="$4"

  local root
  root="$(mktemp --directory)"
  mkdir --parents "${root}/docs"
  printf '# Invariant index\n\n- **Ok** — x → [ok.md](ok.md).\n- **Extra** — x → %s.\n' \
    "${link}" >"${root}/index.md"
  printf '# Ok\n' >"${root}/docs/ok.md"
  if [[ -n ${extra_doc} ]]; then
    printf '# Extra\n' >"${root}/docs/${extra_doc}"
  fi
  run_scenario "${name}" "${root}" 1 "${expected_stderr}"
  rm --recursive --force -- "${root}"
}

# Build an index holding one in-class pointer to an existing doc and the
# given entry line, then run the lint against it. The tree also holds a
# docs/sub/ directory with no doc in it and an outside.md beside docs/, so
# a path through sub/ or out of docs/ resolves.
function run_line_scenario() {
  local -r name="$1"
  local -r line="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"

  local root
  root="$(mktemp --directory)"
  mkdir --parents "${root}/docs/sub"
  printf '# Invariant index\n\n- **Ok** — x → [ok.md](ok.md).\n- **Line** — x → %s.\n' \
    "${line}" >"${root}/index.md"
  printf '# Ok\n' >"${root}/docs/ok.md"
  printf 'not a doc\n' >"${root}/docs/sub/keep.txt"
  printf '# Outside\n' >"${root}/outside.md"
  run_scenario "${name}" "${root}" "${expected_exit}" "${expected_stderr}"
  rm --recursive --force -- "${root}"
}

function main() {
  # The good index also holds a placeholder pointer, which documents the
  # entry shape and must not be reported.
  run_scenario 'good tree passes' 'good' 0 ''
  run_scenario 'orphan index link fails' \
    'bad-orphan-link' 1 'docs/security/missing.md referenced but file missing'
  run_scenario 'unreferenced doc fails' \
    'bad-unreferenced-doc' 1 '[unreferenced-doc] docs/security/bar.md exists'
  # An absent index is a missing input, not a docs/index divergence: the
  # tooling code keeps it out of the drift bucket.
  run_scenario 'absent index is a tooling error' \
    'no-such-fixture' 2 'invariant index not found'

  # The index-line grep and the path sed read the link with one ASCII
  # class under a C locale, so a path holding a non-ASCII letter is never
  # an index entry and its doc stays unreferenced, the verdict CI gives.
  require_grep_locale_gap en_US.UTF-8 || exit 1
  require_sed_locale_gap en_US.UTF-8 || exit 1
  local root
  root="$(mktemp --directory)"
  mkdir --parents "${root}/docs/security"
  printf '# Invariant index\n\n## Security\n\n- **Foo** — one-sentence what → [security/café.md](security/café.md).\n' \
    >"${root}/index.md"
  printf '# Café\n' >"${root}/docs/security/café.md"
  run_scenario 'non-ASCII letter in an index path is unreferenced under en_US.UTF-8' \
    "${root}" 1 '[unreferenced-doc] docs/security/café.md exists' en_US.UTF-8
  rm --recursive --force -- "${root}"

  # Every link on a line is read. Under a C locale only the ASCII-only one
  # is in the class; unpinned, en_US.UTF-8 lets the non-ASCII one in too,
  # which flips whether its doc counts as referenced.
  root="$(mktemp --directory)"
  mkdir --parents "${root}/docs/security"
  printf '# Invariant index\n\n## Security\n\n- **Foo** — x → [security/foo.md](security/foo.md) and [security/café.md](security/café.md).\n' \
    >"${root}/index.md"
  printf '# Foo\n' >"${root}/docs/security/foo.md"
  printf '# Café\n' >"${root}/docs/security/café.md"
  # A third, never-linked doc keeps this output apart from the single-link
  # scenario above, which reports café alone.
  printf '# Zed\n' >"${root}/docs/security/zed.md"
  run_scenario 'last non-ASCII link on an index line leaves only that doc unreferenced' \
    "${root}" 1 '[unreferenced-doc] docs/security/café.md exists' en_US.UTF-8
  rm --recursive --force -- "${root}"

  # A pointer outside the link-path class is reported rather than skipped,
  # so a broken pointer of that shape cannot pass the forward check.
  run_off_class_scenario 'uppercase index pointer is reported' \
    '[Missing.md](Missing.md)' '' 'Missing.md is outside'
  run_off_class_scenario 'leading-digit index pointer is reported' \
    '[1foo.md](1foo.md)' '' '1foo.md is outside'
  run_off_class_scenario 'non-ASCII index pointer is reported' \
    '[naïve.md](naïve.md)' '' 'naïve.md is outside'
  run_off_class_scenario 'URL index pointer is reported' \
    '[a.md](https://example.com/a.md)' '' 'https://example.com/a.md is outside'
  run_off_class_scenario 'parent-relative index pointer is reported' \
    '[README.md](../README.md#top)' '' '../README.md is outside'
  # The target exists, so only the class check can fail the forward half;
  # the reverse half still reports the doc as unreferenced.
  run_off_class_scenario 'off-class pointer to an existing doc is still reported' \
    '[Present.md](Present.md)' 'Present.md' 'Present.md is outside'
  run_off_class_scenario 'off-class pointer to an existing doc leaves the doc unreferenced' \
    '[Here.md](Here.md)' 'Here.md' '[unreferenced-doc] docs/Here.md exists'

  # Each in-class pointer on a line is checked, the first as well as the
  # last.
  run_line_scenario 'first of two pointers on a line is checked' \
    '[missing-a.md](missing-a.md) and [ok.md](ok.md)' 1 \
    'docs/missing-a.md referenced but file missing'
  run_line_scenario 'second of two pointers on a line is checked' \
    '[ok.md](ok.md) and [missing-b.md](missing-b.md)' 1 \
    'docs/missing-b.md referenced but file missing'

  # A dot or empty path segment is outside the class: the target resolves
  # in each case, out of docs/ for the `..` one, so only the class check
  # can fail it.
  run_line_scenario 'dot-dot segment pointer is reported' \
    '[outside.md](sub/../../outside.md)' 1 'sub/../../outside.md is outside'
  run_line_scenario 'single-dot segment pointer is reported' \
    '[ok.md](sub/./../ok.md)' 1 'sub/./../ok.md is outside'
  run_line_scenario 'empty segment pointer is reported' \
    '[ok.md](sub//../ok.md)' 1 'sub//../ok.md is outside'

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
