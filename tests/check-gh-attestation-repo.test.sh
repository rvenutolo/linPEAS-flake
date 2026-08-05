#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-gh-attestation-repo.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/gh-attestation-repo"

failures=0

function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

function pass() {
  printf 'PASS: %s\n' "$1"
}

function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(PATHS_OVERRIDE="${FIXTURES}/${fixture}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    fail "${fixture}"
    printf '  exit %s, want %s\n  stderr: %s\n' "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    fail "${fixture}"
    printf '  stderr missing %q\n  got: %s\n' "${want_msg}" "${got_stderr}" >&2
    return
  fi
  pass "${fixture}"
}

# The lint's scan globs, read out of the script between its markers, so
# the assertions below track the real glob rather than a copy of it.
# Unquoted on purpose at the call sites: git ls-files takes each glob as
# a separate pathspec argument, and IFS is newline+tab so a glob
# containing a space would still split correctly.
function extract_scan_globs() {
  sed --quiet \
    "/^# BEGIN SCAN_GLOBS$/,/^# END SCAN_GLOBS$/{s/^  '\(.*\)'$/\1/p}" \
    "${SCRIPT}"
}

# The glob in the lint decides what gets scanned. A path class that can
# carry a runnable invocation but is named by no glob is never inspected,
# and the lint stays green on a real bypass. Derived from the tracked tree
# rather than hardcoded: this fails if a class stops being selected.
function scenario_glob_selects_new_classes() {
  local globs
  globs="$(extract_scan_globs)"
  # Guard-the-guard: zero globs means the markers moved or were renamed.
  # git ls-files with no pathspec lists the whole repo, so without this the
  # class checks below would all find a match and pass vacuously.
  if [[ -z ${globs} ]]; then
    fail 'SCAN_GLOBS markers yielded no globs — extractor broke'
    return
  fi

  local selected
  # shellcheck disable=SC2046 # each glob must reach git ls-files as its
  # own pathspec argument; splitting on IFS is the point.
  selected="$(cd "${REPO_ROOT}" && git ls-files $(extract_scan_globs))"

  local class missing=0
  for class in '^\.github/actions/.*\.ya?ml$' '^justfile$' '^CHANGELOG\.md$' '^nix/.*\.nix$' '^flake\.nix$' '^treefmt\.nix$'; do
    if ! printf '%s\n' "${selected}" | grep --quiet --extended-regexp -- "${class}"; then
      printf '  no tracked file selected for class: %s\n' "${class}" >&2
      missing=1
    fi
  done

  if ((missing)); then
    fail 'scan globs select no file for at least one path class'
  else
    pass 'scan globs select every named path class'
  fi
}

# The lint and its pre-commit hook must agree on what is in scope. A path
# the glob selects but the hook filter misses is checked in CI and not on
# the per-changed-file commit path, so a bypass lands locally green.
#
# The containment is one-directional: the hook filter also names
# scripts/_attestation_invocations.awk so that editing the parser
# re-triggers the hook, and that file is deliberately not scanned.
function scenario_glob_hook_filter_parity() {
  local -r hooks="${REPO_ROOT}/nix/hooks/workflow-security.nix"

  local files_re
  files_re="$(awk '
    /^  gh-attestation-repo = \{/ { in_block = 1; next }
    in_block && /^  \};/ { exit }
    in_block && match($0, /files = "[^"]*"/) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^files = "/, "", s)
      sub(/"$/, "", s)
      print s
      exit
    }
  ' "${hooks}")"
  if [[ -z ${files_re} ]]; then
    fail 'could not extract files filter for gh-attestation-repo'
    return
  fi

  # Nix string literal: "\\." in source is the ERE "\.".
  local ere
  ere="$(printf '%s' "${files_re}" | sed 's/\\\\/\\/g')"

  local globs
  globs="$(extract_scan_globs)"
  if [[ -z ${globs} ]]; then
    fail 'SCAN_GLOBS markers yielded no globs — extractor broke'
    return
  fi

  local selected
  # shellcheck disable=SC2046 # each glob must reach git ls-files as its
  # own pathspec argument; splitting on IFS is the point.
  selected="$(cd "${REPO_ROOT}" && git ls-files $(extract_scan_globs))"

  local p uncovered=0 seen=0
  while IFS= read -r p; do
    [[ -z ${p} ]] && continue
    seen=$((seen + 1))
    if ! printf '%s\n' "${p}" | grep --quiet --extended-regexp -- "${ere}"; then
      printf '  glob selects a path the hook filter misses: %s\n' "${p}" >&2
      uncovered=1
    fi
  done <<<"${selected}"

  # Guard-the-guard: an empty selection means the marker parse broke.
  if ((seen == 0)); then
    fail 'scan globs selected no tracked file — SCAN_GLOBS parse broke'
    return
  fi

  if ((uncovered)); then
    fail 'gh-attestation-repo files filter does not cover every scanned path'
  else
    pass 'gh-attestation-repo files filter covers every scanned path'
  fi
}

function main() {
  scenario_glob_selects_new_classes
  scenario_glob_hook_filter_parity

  expect good.sh 0 ""
  expect good-eq.sh 0 ""
  expect good-md-prose.md 0 ""
  expect good-md-code.md 0 ""
  expect good-md-inline.md 0 ""
  expect good-yml-comment.yml 0 ""
  expect bad-md-inline.md 1 "missing"
  expect bad-yml-inline.yml 1 "missing"
  expect bad-missing.sh 1 "missing"
  expect bad-wrong-slug.sh 1 "missing"
  expect bad-md-code.md 1 "missing"
  expect good-chain.sh 0 ""
  expect bad-mask-span.md 1 "missing"
  expect bad-chain-unquoted.sh 1 "missing"
  expect bad-span-chain.md 1 "missing"
  expect bad-span-greedy.md 1 "missing"
  expect bad-comment-pin.sh 1 "missing"
  expect bad-separator-pin.sh 1 "missing"
  expect bad-quoted-arg-pin.sh 1 "missing"
  expect bad-doubled-space.sh 1 "missing"
  expect bad-indented-code.md 1 "missing"
  expect bad-tilde-fence.md 1 "missing"
  expect bad-attr-info.md 1 "missing"
  expect bad-doubled-span.md 1 "missing"
  expect bad-nested-span.md 1 "missing"
  expect bad-inline-triple.md 1 "missing"
  expect bad-multiline-span.md 1 "missing"
  expect good-quoted-slug.sh 0 ""
  expect good-odd-backtick.md 0 ""
  expect bad-command-subst.sh 1 "missing"
  expect bad-carry-swallow.yml 1 "missing"
  expect good-command-subst.sh 0 ""
  expect good-short-flag.sh 0 ""
  expect good-glued-short-flag.sh 0 ""
  expect good-redir-pin.sh 0 ""
  expect bad-background-sep.sh 1 "missing"
  expect bad-adjacent-subst.sh 1 "missing"
  expect bad-carry-glue.yml 1 "missing"
  expect good-text-comment.md 0 ""
  expect good-fence-comment.md 0 ""
  expect good-indented-comment.md 0 ""
  expect good-comment-span.sh 0 ""

  if ((failures > 0)); then
    printf '%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf 'all tests passed\n'
}

main "$@"
