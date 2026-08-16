#!/usr/bin/env bash
# scripts/check-renovate-config-validator.sh
#
# @description Validate renovate.json against the upstream Renovate
#   config schema using `renovate-config-validator --strict --no-global`.
#   Catches typoed keys, wrong-type values, and unknown options that
#   per-tool linters miss. Complements scripts/check-renovate-invariants.sh,
#   which asserts repo-policy invariants on top of a valid schema.
#
# Honors RENOVATE_JSON_OVERRIDE for fixture testing.
# Exits 0 on a valid config, 1 on any validation error, 2 when the check
# cannot run — the config is absent, unreadable, not a regular file, or
# the validator itself is not on PATH. None of those says anything about
# the config's validity, so none may borrow the rejection code.
#
# payload-subject-exempt: a malformed config is this script's verdict, not an obstacle to it — the validator rejects one at exit 1, so there is no could-not-run outcome for a scenario to prove

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/payload.sh
source "${_lib_dir}/lib/payload.sh"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
readonly REPO_ROOT
readonly DEFAULT_PATH="${REPO_ROOT}/renovate.json"
readonly path="${RENOVATE_JSON_OVERRIDE:-${DEFAULT_PATH}}"

payload_source_into payload_source RENOVATE_JSON_OVERRIDE 'renovate.json'
readonly payload_source

# This script hands ${path} straight to the external validator rather
# than reading its content itself, so there is no payload to capture —
# but the path still needs the same three could-not-run guards
# read_json_payload_into applies before a read, in the same order, for
# the same reason: a directory passes both the existence and the `-r`
# readability checks in bash (a readable directory's contents can be
# listed), so without the third guard it would reach the validator and
# come back misreported as a rejected config (exit 1) instead of a
# could-not-run (exit 2) — confirmed by feeding the validator a directory
# directly.
if [[ ! -e ${path} ]]; then
  printf 'renovate schema: payload from %s not found\n' "${payload_source}" >&2
  exit 2
fi
if [[ ! -r ${path} ]]; then
  printf 'renovate schema: payload from %s is not readable\n' "${payload_source}" >&2
  exit 2
fi
if [[ ! -f ${path} ]]; then
  printf 'renovate schema: payload from %s could not be read\n' "${payload_source}" >&2
  exit 2
fi

if ! command -v renovate-config-validator >/dev/null 2>&1; then
  printf 'renovate-config-validator not on PATH; enter the devshell first\n' >&2
  exit 2
fi

# --strict: warnings and migrations become errors.
# --no-global: treat input as repo config, not global self-hosted config.
if ! renovate-config-validator --strict --no-global "${path}"; then
  printf 'renovate-config-validator rejected %s\n' "${path}" >&2
  exit 1
fi
