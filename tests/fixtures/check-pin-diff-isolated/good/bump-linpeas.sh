#!/usr/bin/env bash
# fixture: canonical writer pattern
set -Eeuo pipefail
pin_file="$(git rev-parse --show-toplevel)/linpeas-pin.json"
pin_tmp="$(mktemp)"
printf '{"version":"x"}' >"${pin_tmp}"
mv -- "${pin_tmp}" "${pin_file}"
