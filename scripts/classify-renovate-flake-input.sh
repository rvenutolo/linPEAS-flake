#!/usr/bin/env bash
# scripts/classify-renovate-flake-input.sh
#
# @description Classify one Renovate PR title into the flake input that
# PR bumps: prints `pre-commit-hooks`, `nixpkgs-unstable`, or
# `nixpkgs`. Drives the identify job of
# .github/workflows/renovate-flake-lock-refresh.yml, which runs
# `nix flake update <input>` on the PR branch. Pure and side-effect
# free so the mapping is testable without a live Renovate PR.

# Renovate builds the title from the depName declared by the custom
# managers in renovate.json, lowercased. Matching is therefore
# case-insensitive: one manager renders `NixOS/nixpkgs` in config and
# `nixos/nixpkgs` in the title it opens, and a case-sensitive match
# reads the live shape as unmapped — which the caller cannot tell from
# "this PR bumps no flake input" unless the two outcomes exit
# differently. They do, below.
#
# Exit: 0 mapped (input name on stdout), 3 no flake input maps to this
# title, 2 usage error.

set -Eeuo pipefail
IFS=$'\n\t'

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <pr-title>\n' "${0##*/}" >&2
  exit 2
fi

readonly title="$1"

# An empty title means the caller read nothing from the API, not that
# the PR bumps no input: operational, not a classification.
if [[ -z ${title} ]]; then
  printf '%s: empty PR title\n' "${0##*/}" >&2
  exit 2
fi

title_lc="${title,,}"
readonly title_lc

# The nixpkgs-unstable arm MUST precede the nixpkgs arm — the latter is
# a substring of the former, so arm ordering decides the match.
#
# No Renovate manager opens a `nixos/nixpkgs-unstable` title today: that
# input is branch-tracked, so the weekly `nix flake update` cron floats
# it and no bot PR names it. The arm stays anyway, and deleting it as
# dead code is the trap it guards against — without it a title that does
# mention unstable falls through to the `nixos/nixpkgs` arm and drives
# `nix flake update nixpkgs`, refreshing the wrong input under a name
# that looks right.
case "${title_lc}" in
*"cachix/git-hooks.nix"*)
  printf 'pre-commit-hooks\n'
  ;;
*"nixos/nixpkgs-unstable"*)
  printf 'nixpkgs-unstable\n'
  ;;
*"nixos/nixpkgs"*)
  printf 'nixpkgs\n'
  ;;
*)
  printf '%s: no flake input maps to title %q\n' "${0##*/}" "${title}" >&2
  exit 3
  ;;
esac
