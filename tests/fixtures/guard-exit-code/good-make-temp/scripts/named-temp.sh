#!/usr/bin/env bash
# The named-template form, placing the file under a caller-chosen root.
set -Eeuo pipefail
IFS=$'\n\t'

readonly ROOT="${PWD}"
probe="$(make_temp --tmpdir="${ROOT}" probe.XXXXXX)"
trap 'rm --force -- "${probe}"' EXIT

printf 'probe at %s\n' "${probe}"
