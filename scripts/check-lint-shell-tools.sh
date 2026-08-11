#!/usr/bin/env bash
# scripts/check-lint-shell-tools.sh
#
# @description Assert every tool the batched `.#lint`-hosted invariant-lint
# groups (lint-workflow-security, lint-script-hygiene) rely on is present on
# PATH. These groups run inside devShells.lint in CI; this guard turns a
# dropped tool into a named failure instead of a cryptic mid-check error.
# Keep EXPECTED in sync with the lintTools list in nix/devshell-lint.nix.

set -Eeuo pipefail
IFS=$'\n\t'

readonly -a EXPECTED=(bash yq jq gh git shellcheck shfmt actionlint check-jsonschema sed grep awk)

function main() {
  local missing=0 tool
  for tool in "${EXPECTED[@]}"; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      printf '::error::lint shell missing tool on PATH: %s\n' "${tool}" >&2
      missing=1
    fi
  done
  if [[ ${missing} -eq 0 ]]; then
    printf 'all %d expected lint-shell tools present\n' "${#EXPECTED[@]}"
  fi
  exit "${missing}"
}

main "$@"
