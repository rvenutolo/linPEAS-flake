#!/usr/bin/env bash
# scripts/check-path-hygiene.sh
#
# @description Lint: no path tracked in this repo, nor any untracked
# path a commit is about to introduce, may contain a byte in the
# 0x01-0x1F control range or DEL (0x7F). A newline defeats every
# line-oriented path handoff in this repo's own tooling, and a tab
# corrupts the tab-separated inventories those handoffs produce just as
# surely, so both stay in scope alongside the rest of the control range.

# Lint: reject control characters in tracked (and about-to-be-tracked)
# paths.
#
# The hazard: a filename carrying a newline reads as two records to any
# line-oriented consumer — `git ls-files` (without `-z`) C-quotes it onto
# one line, `find` (without `-print0`) splits it across two — and either
# way a downstream `[[ -f ]]` gate can skip a file that exists while the
# scan that produced the list still reports a plausible count. A tab
# does the same to this repo's tab-separated inventories (the harness
# census, the enforcement-matrix TSV) without needing a newline at all.
# `scripts/lib/enumerate.sh` closes this for every converted consumer by
# reading NUL-delimited producer output; this lint closes it for every
# consumer the conversion cannot reach, by refusing to let such a name
# exist in the tree in the first place.
#
# Enumeration source: `git ls-files --cached --others --exclude-standard
# -z`, covering committed paths AND untracked-but-not-ignored ones. The
# latter half matters here for the same reason it matters to
# check-ephemeral-refs.sh: a file a commit is about to introduce is
# gated by the same run that introduces it, rather than by whatever run
# happens to follow the commit that adds it. Ignored paths (build
# output, `node_modules`-shaped trees) are excluded because this lint
# polices what this repo tracks or is about to track, not what a tool
# happened to leave lying around.
#
# Byte range: 0x01-0x1F (every C0 control byte except NUL, which cannot
# appear in a POSIX filename at all) plus 0x7F (DEL, the byte outside
# the C0 block that terminal and line-editing code treats as a control
# character). Tab (0x09) and newline (0x0A) both fall inside 0x01-0x1F,
# so no special-casing is needed to cover them.
#
# Matching runs under LC_ALL=C so the byte range is a byte range even
# against a path that is not valid UTF-8 under the ambient locale — a
# locale-dependent bracket expression would let the very kind of
# malformed input this lint exists to catch make the match itself
# behave unpredictably.
#
# Reporting a hit renders the offending path via `${path@Q}`: the report
# line is otherwise attacker-controlled text (the path itself), and
# `@Q` renders every control byte in it as a `$'...'` escape rather than
# printing it raw, so a path cannot forge a fake report line into this
# script's own output.
#
# Honors LINT_ALLOW_EMPTY_SCAN=1 (from scripts/lib/enumerate.sh) to
# accept an empty scan set.
# Exit 0 clean, 1 on any control-byte path, 2 on a failed or empty
# enumeration.

set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C
# shellcheck source=scripts/lib/enumerate.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/enumerate.sh"

# @description NUL-delimited path producer for `enumerate_into`: every
# path git reports for the current tree, tracked or about to be
# tracked, minus ignored paths.
# @stdout NUL-delimited paths
# shellcheck disable=SC2329 # invoked indirectly, by name, via enumerate_into
function path_hygiene_git_sources() {
  git ls-files --cached --others --exclude-standard -z
}

function main() {
  local -a paths=()
  enumerate_into paths 'git ls-files' path_hygiene_git_sources

  # The bracket expression is built from real bytes via $'...' rather
  # than written as a literal `\x01` escape: POSIX ERE bracket
  # expressions have no `\xNN` escape syntax, so a literal `\x01` would
  # match the four characters `\`, `x`, `0`, `1` instead of the byte.
  local -r control_re=$'[\x01-\x1f\x7f]'

  local failed=0
  local scanned=0
  local p
  for p in "${paths[@]}"; do
    scanned=$((scanned + 1))
    if [[ ${p} =~ ${control_re} ]]; then
      printf '%s: control character in path: %s\n' "${0##*/}" "${p@Q}" >&2
      failed=$((failed + 1))
    fi
  done

  if ((failed > 0)); then
    printf '%d path(s) contain a control byte (0x01-0x1F) or DEL (0x7F)\n' "${failed}" >&2
    exit 1
  fi

  printf 'path-hygiene: %d path(s) scanned, 0 control-byte violations\n' "${scanned}"
  exit 0
}

main "$@"
