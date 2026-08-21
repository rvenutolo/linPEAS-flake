#!/usr/bin/env bash
# scripts/classify-renovate-pr-author.sh
#
# @description Classify one PR author login as Renovate or not, printing
# the canonical `renovate` spelling when it is. Drives the identify job
# of .github/workflows/renovate-flake-lock-refresh.yml, which refreshes
# `flake.lock` only on a PR that Renovate opened. Pure and side-effect
# free so the mapping is testable without a live Renovate PR.

# The login GitHub reports for the same App differs by how it is read.
# `gh pr view --json author` renders an App as `app/<slug>`, the REST
# and GraphQL APIs render the installed bot account as `<slug>[bot]`,
# and a self-hosted legacy install shows the bare user `<slug>`. All
# three name the same author, so this normalizes rather than listing
# spellings inline at each call site — an inline list is what let
# `app/renovate` read as "not Renovate" and skip every PR silently.
#
# Normalization is deliberately narrow: one optional `app/` prefix and
# one optional `[bot]` suffix, then an exact match against `renovate`.
# A login that merely CONTAINS `renovate` is not accepted — `renovate`
# is a claimable username shape, and a substring match would let
# `not-renovate` drive a workflow that pushes commits to a PR branch.
#
# Exit: 0 Renovate (canonical login on stdout), 3 some other author,
# 2 usage error.

set -Eeuo pipefail
IFS=$'\n\t'

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <author-login>\n' "${0##*/}" >&2
  exit 2
fi

readonly login="$1"

# An empty login means the caller read nothing from the API, not that
# the PR has some other author: operational, not a classification.
if [[ -z ${login} ]]; then
  printf '%s: empty author login\n' "${0##*/}" >&2
  exit 2
fi

normalized="${login,,}"
normalized="${normalized#app/}"
normalized="${normalized%\[bot\]}"
readonly normalized

if [[ ${normalized} != "renovate" ]]; then
  printf '%s: author %q is not Renovate\n' "${0##*/}" "${login}" >&2
  exit 3
fi

printf 'renovate\n'
