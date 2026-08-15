#!/usr/bin/env bash
# Fixture: the banned shape written as a bare unquoted word, which the
# parser reports as a plain literal rather than as a quoted string.
set -Eeuo pipefail
IFS=$'\n\t'

bare_source=RENOVATE_JSON_OVERRIDE
printf '%s\n' "${bare_source}"
