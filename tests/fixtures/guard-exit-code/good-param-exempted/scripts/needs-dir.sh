#!/usr/bin/env bash
# The same expansion, with the marker naming why an unset value here is
# the finding rather than a could-not-run.
set -Eeuo pipefail
IFS=$'\n\t'

target="${1:?internal invariant: the caller above always passes a target}" # exit-code-exempt: unset here is a programming error in this repo, not an operator typo
printf 'target %s\n' "${target}"
