#!/usr/bin/env bash
# Fixture: the banned shape written with a double-quoted literal, which
# the parser reports as a quoted word wrapping one plain literal part.
set -Eeuo pipefail
IFS=$'\n\t'

quoted_source="RENOVATE_JSON_OVERRIDE"
printf '%s\n' "${quoted_source}"
