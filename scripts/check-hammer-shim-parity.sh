#!/usr/bin/env bash
# scripts/check-hammer-shim-parity.sh
#
# @description Lint: nix/hammer-shim.nix's linpeas derivation matches
# the canonical linpeas derivation in nix/pin.nix. The
# shim duplicates the derivation because `builtins.getFlake` cannot run
# inside the `nix flake check` sandbox. Compares bodies normalized to
# whitespace-collapsed form.
# Exits 0 on match, 1 on drift, 2 if extraction fails.
#
# Env overrides (test-only):
#   FLAKE_NIX_OVERRIDE    — path to the canonical derivation source to read
#   HAMMER_SHIM_OVERRIDE  — path to nix/hammer-shim.nix to read
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf '.')"
readonly REPO_ROOT
readonly FLAKE_NIX="${FLAKE_NIX_OVERRIDE:-${REPO_ROOT}/nix/pin.nix}"
readonly HAMMER_SHIM="${HAMMER_SHIM_OVERRIDE:-${REPO_ROOT}/nix/hammer-shim.nix}"

extract() {
  # Extract from `pkgs.stdenvNoCC.mkDerivation {` through its matching
  # closing brace+semicolon, brace-depth tracked.
  awk '
    /pkgs\.stdenvNoCC\.mkDerivation \{/ { capture = 1; depth = 0 }
    capture {
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        if (c == "}") {
          depth--
          if (depth == 0) { print substr($0, 1, i); exit }
        }
      }
      print
    }
  ' "$1" | tr -s '[:space:]' ' '
}

a=$(extract "${FLAKE_NIX}")
b=$(extract "${HAMMER_SHIM}")
if [[ -z ${a} || -z ${b} ]]; then
  echo "hammer-shim parity: could not extract derivation block from one of the files" >&2
  exit 2
fi
if [[ ${a} != "${b}" ]]; then
  echo "hammer-shim parity drift: nix/hammer-shim.nix linpeas derivation != flake.nix" >&2
  diff <(printf '%s\n' "${a}" | tr ' ' '\n') <(printf '%s\n' "${b}" | tr ' ' '\n') >&2 || true
  exit 1
fi
