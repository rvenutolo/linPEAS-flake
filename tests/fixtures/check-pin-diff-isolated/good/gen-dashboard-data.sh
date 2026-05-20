#!/usr/bin/env bash
# fixture: read-only access to pin file, should not flag as writer
set -Eeuo pipefail
PIN_FILE="$(git rev-parse --show-toplevel)/linpeas-pin.json"
version="$(jq -r .version "${PIN_FILE}")"
printf 'pin version: %s\n' "${version}"
