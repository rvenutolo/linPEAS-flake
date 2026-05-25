#!/usr/bin/env bash
# Refuse if nix/hammer-shim.nix's linpeas derivation has drifted from
# flake.nix's linpeas derivation. The shim duplicates the derivation
# because `builtins.getFlake` cannot run inside the `nix flake check`
# sandbox (it tries to refetch inputs from github.com).
#
# Compares the bodies normalized to whitespace-collapsed form. Exits
# non-zero on diff.
set -Eeuo pipefail
IFS=$'\n\t'

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

a=$(extract flake.nix)
b=$(extract nix/hammer-shim.nix)
if [[ -z "${a}" || -z "${b}" ]]; then
  echo "hammer-shim parity: could not extract derivation block from one of the files" >&2
  exit 2
fi
if [[ "${a}" != "${b}" ]]; then
  echo "hammer-shim parity drift: nix/hammer-shim.nix linpeas derivation != flake.nix" >&2
  diff <(printf '%s\n' "${a}" | tr ' ' '\n') <(printf '%s\n' "${b}" | tr ' ' '\n') >&2 || true
  exit 1
fi
