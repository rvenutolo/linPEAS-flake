#!/usr/bin/env bash
# Fixture: all three bump-integrity guards present. Not a runnable
# bump — only the guard signatures the check greps for matter. Vars
# are assigned stub values so shellcheck sees them as defined; the
# script is never executed, only grepped.
set -Eeuo pipefail
asset_url='https://github.com/peass-ng/PEASS-ng/releases/download/x/linpeas.sh'
asset_digest='sha256:deadbeef'
tmpfile='/tmp/example-download'
new_pin='{}'
pin_file='/tmp/example-linpeas-pin.json'
expected_url_prefix='https://github.com/peass-ng/PEASS-ng/releases/download/'
[[ ${asset_url} != "${expected_url_prefix}"* ]] && exit 1
[[ ${asset_digest} != sha256:* ]] && exit 1
actual_sha_line="$(sha256sum "${tmpfile}")"
printf '%s\n' "${actual_sha_line}" >/dev/null
pin_tmp="$(mktemp)"
printf '%s\n' "${new_pin}" >"${pin_tmp}"
mv -- "${pin_tmp}" "${pin_file}"
