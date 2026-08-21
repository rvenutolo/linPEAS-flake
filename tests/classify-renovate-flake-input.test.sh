#!/usr/bin/env bash
# tests/classify-renovate-flake-input.test.sh
#
# Verdict + failure-mode matrix for
# scripts/classify-renovate-flake-input.sh. Pure classifier: one PR
# title in, one flake input name out. Offline and deterministic.
#
# The mapped cases below are titles Renovate actually opened against
# this repo, not titles derived from its templates. That distinction is
# what this harness protects. Renovate lowercases dep names in titles,
# so a mapping written from the depName casing in renovate.json matches
# nothing a real PR carries — and it fails silently, because an
# unmapped title means the lock refresh simply does not run.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/classify-renovate-flake-input.sh"

failures=0

# @arg $1 description  @arg $2 expected stdout, or "<exit:N>" for a
#   non-zero exit whose exact code is the assertion
# remaining args: passed through to the classifier
function classify() {
  local -r desc="$1" want="$2"
  shift 2
  local got rc=0
  got="$(bash "${SCRIPT}" "$@" 2>/dev/null)" || rc=$?
  if [[ ${want} == "<exit:"* ]]; then
    local -r want_rc="${want#<exit:}"
    if [[ ${rc} -ne ${want_rc%>} ]]; then
      printf 'FAIL %s: exit %d, want %s\n' "${desc}" "${rc}" "${want}" >&2
      failures=1
      return
    fi
    printf 'OK   %s (exit %d)\n' "${desc}" "${rc}"
    return
  fi
  if [[ ${rc} -ne 0 ]]; then
    printf 'FAIL %s: exit %d, want %s\n' "${desc}" "${rc}" "${want}" >&2
    failures=1
    return
  fi
  if [[ ${got} != "${want}" ]]; then
    printf 'FAIL %s: got %q want %q\n' "${desc}" "${got}" "${want}" >&2
    failures=1
    return
  fi
  printf 'OK   %s\n' "${desc}"
}

# --- titles Renovate actually opened against this repo -------------
classify "live nixpkgs stable title" nixpkgs \
  'chore(deps): update dependency nixos/nixpkgs to v26'
classify "live nixpkgs-unstable title" nixpkgs-unstable \
  'chore(deps): update nixos/nixpkgs-unstable digest to 0ae2bc1'
classify "live git-hooks.nix title" pre-commit-hooks \
  'chore(deps): update cachix/git-hooks.nix digest to 43b3c1a'

# --- the substring hazard ------------------------------------------
# `nixos/nixpkgs` is a prefix of `nixos/nixpkgs-unstable`, so an arm
# ordering that puts stable first classifies every unstable bump as
# stable and refreshes the wrong input. Asserted from both directions
# so a reordering cannot pass by fixing one and breaking the other.
#
# These stay asserted even though no Renovate manager emits an unstable
# title any more — the branch-tracked input is floated by the weekly
# cron instead. The arm is the guard, and the guard is what makes
# deleting it as dead code a silent misclassification rather than a
# no-op.
classify "unstable is not swallowed by the stable arm" nixpkgs-unstable \
  'update nixos/nixpkgs-unstable digest'
classify "stable is not widened into unstable" nixpkgs \
  'update nixos/nixpkgs to v26'

# --- case insensitivity, both directions ---------------------------
# renovate.json declares depName `NixOS/nixpkgs`; the PR title carries
# `nixos/nixpkgs`. Both must map, so neither a config-shaped nor a
# title-shaped string is a special case.
classify "config-cased depName still maps" nixpkgs \
  'Update NixOS/nixpkgs to v26'
classify "config-cased unstable still maps" nixpkgs-unstable \
  'Update NixOS/nixpkgs-unstable to nixos-unstable'
classify "screaming case maps" pre-commit-hooks \
  'UPDATE CACHIX/GIT-HOOKS.NIX DIGEST TO 43B3C1A'

# --- unmapped is a verdict, not a failure --------------------------
# Exit 3 is what lets the caller file an issue for an unrecognized
# title while still treating a broken invocation (exit 2) differently.
classify "action-bump title maps to no flake input" "<exit:3>" \
  'chore(deps): update github-actions'
classify "unrelated title maps to no flake input" "<exit:3>" \
  'docs: fix a typo'

# --- operational errors --------------------------------------------
classify "empty title is operational, not unmapped" "<exit:2>" ''
classify "no argument" "<exit:2>"
classify "too many arguments" "<exit:2>" 'a' 'b'

if [[ ${failures} -ne 0 ]]; then
  printf '\nclassify-renovate-flake-input: FAILURES\n' >&2
  exit 1
fi
printf '\nclassify-renovate-flake-input: all passed\n'
