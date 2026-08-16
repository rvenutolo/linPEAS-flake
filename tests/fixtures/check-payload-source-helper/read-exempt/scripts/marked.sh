#!/usr/bin/env bash
# Fixture: the banned shape, excused by a marker carrying a rationale.
set -Eeuo pipefail
IFS=$'\n\t'

readonly notes_path
# payload-read-exempt: reads a non-JSON asset the payload helper does not cover
notes="$(cat -- "${notes_path}")"
printf '%s\n' "${notes}"
