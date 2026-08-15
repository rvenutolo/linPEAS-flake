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
# cannot run — the config file is absent, or the validator itself is not
# on PATH. Neither says anything about the config's validity, so neither
# may borrow the rejection code.
#
# payload-subject-exempt: a malformed config is this script's verdict, not an obstacle to it — the validator rejects one at exit 1, so there is no could-not-run outcome for a scenario to prove

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
readonly REPO_ROOT
readonly DEFAULT_PATH="${REPO_ROOT}/renovate.json"
readonly path="${RENOVATE_JSON_OVERRIDE:-${DEFAULT_PATH}}"

if [[ ! -f ${path} ]]; then
  printf 'renovate config not found: %s\n' "${path}" >&2
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
