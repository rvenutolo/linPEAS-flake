#!/usr/bin/env bash
# scripts/check-jsonschema.sh
#
# @description Validate repo config files (renovate.json, workflow
# YAML, composite-action YAML, .markdownlint.json) against pinned
# JSON Schemas using `check-jsonschema`.

# Validate repo config files against JSON Schemas. Catches schema-shape
# regressions (typoed keys, wrong types, removed-by-upstream fields)
# that the file-specific linters can miss.
#
# Schemas:
#   - renovate.json                       — check-jsonschema builtin
#                                           `vendor.renovate`
#   - .github/workflows/*.yml             — builtin `vendor.github-workflows`
#   - .github/actions/**/action.yml       — builtin `vendor.github-actions`
#   - .markdownlint.json                  — SchemaStore-pinned schema
#                                           (see SCHEMASTORE_SHA below)
#
# Builtin schemas ship with check-jsonschema and are pinned by the
# nixpkgs revision in flake.lock. The SchemaStore schema is pinned by
# commit SHA; Renovate's customManager (`schemastore-pin` in
# renovate.json) bumps it on the same cadence as other tracked SHAs.
#
# Exit codes:
#   0  no file failed schema validation
#   1  at least one file failed schema validation
#   2  the check could not run: `check-jsonschema` is not on PATH, or a
#      scan set — workflow YAML, composite-action YAML — matched no
#      file, which would otherwise print a clean verdict having
#      validated nothing

set -Eeuo pipefail
IFS=$'\n\t'
# Resolved before the `cd` below: `BASH_SOURCE`-relative sourcing after a
# directory change would look for the library under the new working
# directory.
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"

# renovate: datasource=git-refs depName=SchemaStore/schemastore packageName=https://github.com/SchemaStore/schemastore currentValue=master
readonly SCHEMASTORE_SHA='ecae713b273dfed09cb9e29398f21b7da0bf9cd9'

readonly MARKDOWNLINT_SCHEMA_URL="https://raw.githubusercontent.com/SchemaStore/schemastore/${SCHEMASTORE_SHA}/src/schemas/json/markdownlint.json"

function log() {
  printf '[%s] %-5s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" >&2
}
function log_info() { log INFO "$*"; }
function log_err() { log ERROR "$*"; }

if ! command -v check-jsonschema >/dev/null 2>&1; then
  log_err 'check-jsonschema not on PATH'
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"

failed=0

function run_check() {
  local label="$1"
  shift
  log_info "validating ${label}"
  if ! check-jsonschema "$@"; then
    log_err "${label}: schema validation failed"
    failed=1
  fi
}

if [[ -f renovate.json ]]; then
  run_check 'renovate.json' --builtin-schema vendor.renovate renovate.json
fi

# Each set is asserted on its own. A tree holding no workflow — or no
# composite action — validates nothing here, and the run then reports `all
# schema validations passed` having read not one file, which is a
# could-not-run wearing a clean verdict.
declare -a workflow_files=()
glob_into workflow_files 'workflow YAML' '.github/workflows/*.yml' '.github/workflows/*.yaml'
run_check 'github-workflows' --builtin-schema vendor.github-workflows "${workflow_files[@]}"

declare -a action_files=()
# `**` also matches zero segments, so this covers both
# `.github/actions/<name>/action.yml` and a bare `.github/actions/action.yml`.
shopt -s globstar
glob_into action_files 'composite-action YAML' '.github/actions/**/action.yml' '.github/actions/**/action.yaml'
shopt -u globstar
run_check 'github-actions' --builtin-schema vendor.github-actions "${action_files[@]}"

if [[ -f .markdownlint.json ]]; then
  run_check 'markdownlint config' --schemafile "${MARKDOWNLINT_SCHEMA_URL}" .markdownlint.json
fi

if ((failed != 0)); then
  log_err 'one or more schema validations failed'
  exit 1
fi

log_info 'all schema validations passed'
