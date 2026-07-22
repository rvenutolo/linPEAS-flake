#!/usr/bin/env bash
# Fixture: .digest cross-check removed. Vars are assigned stub
# values so shellcheck sees them as defined; the script is never
# executed, only grepped.
set -Eeuo pipefail
asset_url='https://github.com/peass-ng/PEASS-ng/releases/download/x/linpeas.sh'
pin_file='/tmp/example-linpeas-pin.json'
expected_url_prefix='https://github.com/peass-ng/PEASS-ng/releases/download/'
[[ ${asset_url} != "${expected_url_prefix}"* ]] && exit 1
pin_tmp="$(mktemp)"
mv -- "${pin_tmp}" "${pin_file}"
