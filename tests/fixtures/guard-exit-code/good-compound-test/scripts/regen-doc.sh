#!/usr/bin/env bash
# The generated doc being absent and the generated doc being stale are
# one verdict here, so the branch is reachable without anything being
# missing and the exit reports drift correctly.
set -Eeuo pipefail
IFS=$'\n\t'

readonly output_file='docs/generated.md'
tmp_out="$(make_temp)"
readonly tmp_out

printf 'generated\n' >"${tmp_out}"

if [[ ! -f ${output_file} ]] || ! cmp --silent -- "${output_file}" "${tmp_out}"; then
  printf '%s is stale; re-run the generator\n' "${output_file}" >&2
  exit 1
fi

printf 'ok\n'
