#!/usr/bin/env bash
# Fixture: asset-URL-prefix guard removed. Vars are assigned stub
# values so shellcheck sees them as defined; the script is never
# executed, only grepped.
set -Eeuo pipefail
asset_digest='sha256:deadbeef'
tmpfile='/tmp/example-download'
pin_file='/tmp/example-linpeas-pin.json'
[[ ${asset_digest} != sha256:* ]] && exit 1
actual_sha_line="$(sha256sum "${tmpfile}")"
printf '%s\n' "${actual_sha_line}" >/dev/null
pin_tmp="$(make_temp)"
mv -- "${pin_tmp}" "${pin_file}"
