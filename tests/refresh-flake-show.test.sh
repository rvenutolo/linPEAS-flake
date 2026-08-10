#!/usr/bin/env bash
# tests/refresh-flake-show.test.sh
#
# Round-trip + stale-detection + marker-guard harness for
# scripts/refresh-flake-show.sh. The generator has no output-override
# env and reads docs/reference/flake-outputs.md directly, so the
# mutating assertions back up the real doc and restore it via an EXIT
# trap — a failed assertion never leaves the working tree dirty.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/refresh-flake-show.sh"
readonly DOC="${REPO_ROOT}/docs/reference/flake-outputs.md"

failures=0

# Back up the real doc once; restore on any exit.
BACKUP="$(mktemp)"
cp -- "${DOC}" "${BACKUP}"
readonly BACKUP
function cleanup_test() {
  cp -- "${BACKUP}" "${DOC}"
  rm --force -- "${BACKUP}"
}
trap cleanup_test EXIT

function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

function main() {
  local stderr_file actual_exit

  # Assertion 1: committed doc is fresh — --check exits 0 (round-trip).
  if "${SCRIPT}" --check >/dev/null 2>&1; then
    pass 'committed flake-outputs.md is fresh (--check clean)'
  else
    fail '--check reports committed flake-outputs.md stale'
  fi

  # Assertion 2: --check catches drift. Insert a junk line just before
  # the END marker (inside the managed block) so the committed doc
  # diverges from the freshly generated block; expect exit 1 + message.
  stderr_file="$(mktemp)"
  actual_exit=0
  awk '
    /^<!-- END flake-show -->$/ { print "CORRUPTED-BY-HARNESS" }
    { print }
  ' "${BACKUP}" >"${DOC}"
  "${SCRIPT}" --check >/dev/null 2>"${stderr_file}" || actual_exit=$?
  harness_assert_record 'stale block detected' 'is stale' "${stderr_file}"
  if [[ ${actual_exit} -eq 1 ]] &&
    grep --fixed-strings --quiet -- 'is stale' "${stderr_file}"; then
    pass 'stale block detected (--check exit 1 + stale message)'
  else
    fail "stale detection: expected exit 1 + 'is stale', got exit ${actual_exit}"
    cat -- "${stderr_file}" >&2
  fi
  cp -- "${BACKUP}" "${DOC}"
  rm --force -- "${stderr_file}"

  # Assertion 3: missing BEGIN marker → exit 1 + marker message. The
  # guard fires before any nix eval.
  stderr_file="$(mktemp)"
  actual_exit=0
  grep --invert-match --fixed-strings -- '<!-- BEGIN flake-show -->' \
    "${BACKUP}" >"${DOC}"
  "${SCRIPT}" --check >/dev/null 2>"${stderr_file}" || actual_exit=$?
  harness_assert_record 'missing BEGIN marker detected' \
    'BEGIN marker missing' "${stderr_file}"
  if [[ ${actual_exit} -eq 1 ]] &&
    grep --fixed-strings --quiet -- 'BEGIN marker missing' "${stderr_file}"; then
    pass 'missing BEGIN marker detected (--check exit 1 + marker message)'
  else
    fail "marker guard: expected exit 1 + 'BEGIN marker missing', got exit ${actual_exit}"
    cat -- "${stderr_file}" >&2
  fi
  cp -- "${BACKUP}" "${DOC}"
  rm --force -- "${stderr_file}"

  # Assertion 4: the generator no longer discards nix stderr.
  if grep -Eq 'nix flake show .*2>[[:space:]]*/dev/null' "${SCRIPT}"; then
    fail 'nix flake show still discards stderr to /dev/null'
  else
    pass 'nix flake show stderr is surfaced on failure'
  fi

  # Assertion 5: markers the anchored awk splice cannot match (trailing
  # whitespace on BOTH markers) must be rejected by the guard, not silently
  # emitted unchanged. An unanchored guard grep false-greens here — awk
  # matches neither marker, emits the doc verbatim, and --check cmp reports
  # it fresh even when the block is stale. The anchored guard fails closed
  # with a marker-missing message.
  stderr_file="$(mktemp)"
  actual_exit=0
  sed -e 's/^<!-- BEGIN flake-show -->$/<!-- BEGIN flake-show --> /' \
    -e 's/^<!-- END flake-show -->$/<!-- END flake-show --> /' \
    "${BACKUP}" >"${DOC}"
  "${SCRIPT}" --check >/dev/null 2>"${stderr_file}" || actual_exit=$?
  harness_assert_record 'whitespace-perturbed markers rejected' \
    'marker missing' "${stderr_file}"
  if [[ ${actual_exit} -eq 1 ]] &&
    grep --fixed-strings --quiet -- 'marker missing' "${stderr_file}"; then
    pass 'whitespace-perturbed markers rejected (fail-closed, not false-green)'
  else
    fail "whitespace marker guard: expected exit 1 + 'marker missing', got exit ${actual_exit}"
    cat -- "${stderr_file}" >&2
  fi
  cp -- "${BACKUP}" "${DOC}"
  rm --force -- "${stderr_file}"

  # Assertion 6: the flake-show-fresh pre-commit hook must watch every
  # nix module flake.nix imports. The flake outputs this generator reads
  # are defined in those modules, not in the flake.nix entrypoint; a
  # filter naming only flake.nix leaves the generated doc stale on the
  # per-changed-file commit path.
  local -a modules=()
  local m
  while IFS= read -r m; do
    [[ -z ${m} ]] && continue
    modules+=("${m}")
  done < <(awk '
    /^      imports = \[/ { in_imports = 1; next }
    in_imports && /^      \];/ { exit }
    in_imports && match($0, /\.\/nix\/[A-Za-z0-9._\/-]+\.nix/) {
      print substr($0, RSTART + 2, RLENGTH - 2)
    }
  ' "${REPO_ROOT}/flake.nix" | sort --unique)

  # Guard-the-guard: zero imports means the awk parser broke on a
  # reformat. Fail loud rather than vacuously pass.
  if [[ ${#modules[@]} -eq 0 ]]; then
    fail 'no ./nix/*.nix imports parsed from flake.nix — parser broke'
  else
    local files_re
    files_re="$(awk '
      /^  flake-show-fresh = \{/ { in_block = 1; next }
      in_block && /^  \};/ { exit }
      in_block && match($0, /files = "[^"]*"/) {
        s = substr($0, RSTART, RLENGTH)
        sub(/^files = "/, "", s)
        sub(/"$/, "", s)
        print s
        exit
      }
    ' "${REPO_ROOT}/nix/hooks/freshness.nix")"

    if [[ -z ${files_re} ]]; then
      fail 'could not extract files filter for flake-show-fresh'
    else
      # Nix string literal: "\\." in source is the ERE "\.".
      local ere
      ere="$(printf '%s' "${files_re}" | sed 's/\\\\/\\/g')"
      local p uncovered=0
      for p in "${modules[@]}"; do
        if ! printf '%s\n' "${p}" |
          grep --quiet --extended-regexp -- "${ere}"; then
          printf '  uncovered module: %s\n' "${p}" >&2
          uncovered=1
        fi
      done
      if ((uncovered)); then
        fail 'flake-show-fresh files filter does not cover every imported nix module'
      else
        pass 'flake-show-fresh files filter covers every imported nix module'
      fi
    fi
  fi

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '%d failure(s)\n' "${failures}" >&2
    exit 1
  fi
  printf 'all passed\n'
}

main "$@"
