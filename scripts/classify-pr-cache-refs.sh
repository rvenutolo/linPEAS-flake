#!/usr/bin/env bash
# scripts/classify-pr-cache-refs.sh
#
# @description Print the cache refs actions-cache-prune's PR-close job
# deletes for one closed PR, one per line: always the PR's
# `refs/pull/<n>/merge`, then `refs/heads/<head-ref>` only when the head
# ref holds nothing but ASCII letters, digits, `.`, `_`, `/` and `-`.
#
# The head ref is a branch name anyone with push access chooses, and git
# allows characters that change the cache listing query it is placed in:
# `&` or `?` adds query parameters that select other refs' caches, which
# the job then deletes, and `{owner}`, `{repo}` or `{branch}` is a
# placeholder `gh api` expands. A head ref outside the allowed set is
# skipped with a notice on stderr rather than escaped; its caches age out
# in the daily sweep. The match runs under `C.UTF-8`, where the ranges
# hold ASCII only, so a non-ASCII letter or digit is skipped in every
# locale.
#
# Usage:
#   classify-pr-cache-refs.sh <pr-number> <head-ref>
#
# Exit codes:
#   0  the refs were printed (a skipped head ref is a verdict, not a
#      failure)
#   2  bad arguments: not two, or a PR number that is not ASCII digits

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/ascii-match.sh
source "${_lib_dir}/lib/ascii-match.sh"

if [[ $# -ne 2 ]]; then
  printf 'usage: %s <pr-number> <head-ref>\n' "${0##*/}" >&2
  exit 2
fi
readonly pr_number="$1" head_ref="$2"

if ! ascii_match "${pr_number}" '^[0-9]+$'; then
  printf 'PR number %q is not ASCII digits\n' "${pr_number}" >&2
  exit 2
fi

printf 'refs/pull/%s/merge\n' "${pr_number}"
if ascii_match "${head_ref}" '^[A-Za-z0-9._/-]+$'; then
  printf 'refs/heads/%s\n' "${head_ref}"
else
  printf 'skipping head ref %q: it holds a character outside A-Z a-z 0-9 . _ / -; its caches age out in the daily sweep\n' \
    "${head_ref}" >&2
fi
