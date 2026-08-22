#!/usr/bin/env bash
# scripts/check-flake-systems-eval.sh
#
# @description Assert every system declared in `flake.lib.systems`
# evaluates, forcing each package's derivation (not just the attribute
# names) so a package whose value throws is caught. Fails naming the
# offending system + the real nix error, so a platform drop in a nixpkgs
# bump is diagnosable at a glance.
# @option --flake <dir> flake to check (default: repo root)
#
# Exits 0 when every declared system evaluates, 1 when one or more fail
# to evaluate or when the flake declares no systems at all. Exits 2 when
# the check cannot run: an unrecognized argument, `--flake` given with no
# directory, a flake whose `lib.systems` cannot be read, `nix` or `jq`
# absent from PATH, or a temp file that cannot be created.
set -Eeuo pipefail
IFS=$'\n\t'
# The library directory is resolved by parameter expansion rather than by
# `readlink`/`dirname`, so a script whose PATH is missing the tool it is
# about to guard dies in its own guard naming that tool, not at this line
# naming `readlink`. The fallback covers an invocation with a bare
# filename, where the expansion strips nothing.
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"
install_err_trap

function main() {
  local flake='.'
  if [[ ${1:-} == '--flake' ]]; then
    # Guarded explicitly rather than through a `${2:?}` expansion, whose
    # status is bash's own 1. Both branches of this `if` describe one
    # fault — a command line the check cannot use — and neither evaluates
    # anything, so both are could-not-runs. Exit 1 here would tell a
    # caller a declared system failed to evaluate.
    if [[ -z ${2:-} ]]; then
      log_err '--flake needs a directory'
      exit 2
    fi
    flake="$2"
  elif [[ -n ${1:-} ]]; then
    log_err "unknown arg: ${1}"
    exit 2
  fi
  require_tool nix
  require_tool jq

  # The read's status separates two verdicts a bare `set -e` collapses:
  # an eval that failed means the systems list was never read, which is a
  # could-not-run, while an eval that succeeded and returned nothing is a
  # flake that declares no systems, which is the finding. Left unchecked,
  # a `--flake` pointing at a directory holding no flake ends the run
  # under jq's status with the ERR trap's raw line as its only diagnostic.
  # nix keeps its stderr here so that the could-not-run names the real
  # reason the flake could not be read.
  local systems
  if ! systems="$(nix eval --json "${flake}#lib.systems" | jq -r '.[]')"; then
    log_err "cannot read ${flake}#lib.systems"
    exit 2
  fi
  if [[ -z ${systems} ]]; then
    log_err "no systems in ${flake}#lib.systems"
    exit 1
  fi

  local rc=0 sys err
  err="$(make_temp)"
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
