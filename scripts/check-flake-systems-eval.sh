#!/usr/bin/env bash
# scripts/check-flake-systems-eval.sh
#
# @description Assert every system declared in `flake.lib.systems`
# evaluates, forcing each package's derivation (not just the attribute
# names) so a package whose value throws is caught. Fails naming the
# offending system + the real nix error, so a platform drop in a nixpkgs
# bump is diagnosable at a glance.
# @option --flake <dir> flake to check (default: repo root)
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/log.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/log.sh"
install_err_trap

function main() {
  local flake='.'
  if [[ ${1:-} == '--flake' ]]; then
    flake="${2:?--flake needs a dir}"
  elif [[ -n ${1:-} ]]; then
    log_err "unknown arg: ${1}"
    exit 2
  fi
  require_tool nix
  require_tool jq

  local systems
  systems="$(nix eval --json "${flake}#lib.systems" 2>/dev/null | jq -r '.[]')"
  if [[ -z ${systems} ]]; then
    log_err "no systems in ${flake}#lib.systems"
    exit 1
  fi

  local rc=0 sys err
  err="$(mktemp)"
  trap 'rm --force -- "${err:-}"' EXIT
  while IFS= read -r sys; do
    log_info "evaluating ${sys}"
    # Map to drvPath rather than attrNames: --json forces the result to
    # strings, instantiating every package's derivation, so a package
    # whose value throws is caught. attrNames forces only the attrset
    # spine and never touches the values.
    if ! nix eval --json "${flake}#packages.${sys}" \
      --apply 'ps: builtins.mapAttrs (_: p: p.drvPath) ps' \
      >/dev/null 2>"${err}"; then
      log_err "system ${sys} failed to evaluate:"
      cat -- "${err}" >&2
      rc=1
    fi
  done <<<"${systems}"
  trap - ERR
  return "${rc}"
}
main "$@"
