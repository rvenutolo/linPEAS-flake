#!/usr/bin/env bash
# An exemption marker with nothing after the colon is drift, not an
# exemption: honoring it would make the marker a way to opt out of
# stating a reason.
set -Eeuo pipefail
IFS=$'\n\t'

# enumerate-exempt:
sources="$(git ls-tree --name-only -r HEAD -- docs)"
printf '%s\n' "${sources}"
