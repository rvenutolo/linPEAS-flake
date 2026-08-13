#!/usr/bin/env bash
# A sanctioned exception: the marker states why the helper is the wrong
# instrument here rather than merely asserting that it is.
set -Eeuo pipefail
IFS=$'\n\t'

listing="$(mktemp)"
# enumerate-exempt: output feeds diff as a file operand, so diff's own
# status is what the caller acts on
find . -type f -name '*.md' | sort >"${listing}"
rm --force -- "${listing}"
