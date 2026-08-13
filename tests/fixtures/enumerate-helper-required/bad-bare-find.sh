#!/usr/bin/env bash
# A producer feeding a redirection with nothing asserting how much it
# found: an empty scan set here reads exactly like a clean tree.
set -Eeuo pipefail
IFS=$'\n\t'

out="$(mktemp)"
find . -type f -name '*.md' -print0 >"${out}"
rm --force -- "${out}"
