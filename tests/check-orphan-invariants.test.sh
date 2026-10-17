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

function main() {
  run_scenario 'good tree passes' 'good' 0 ''
  run_scenario 'orphan index link fails' \
    'bad-orphan-link' 1 '[orphan-link]'
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

  # The path sed is greedy, so it reads the last link on a line. Under a
  # C locale that is the last ASCII-only link; unpinned, en_US.UTF-8 lets it
  # take the non-ASCII one, which flips which doc counts as referenced.
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

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
