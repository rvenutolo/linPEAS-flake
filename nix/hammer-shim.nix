# Adapter that re-exposes the current flake's package set in the
# `{ overlays }`-arg shape `nixpkgs-hammer` requires. Loading via
# `builtins.getFlake` keeps the derivation single-sourced in flake.nix.
#
# `overlays` is accepted (and ignored) because `nixpkgs-hammer` always
# passes it; the flake already pins nixpkgs and nixpkgs-unstable inputs.
{
  overlays ? [ ],
  system ? builtins.currentSystem,
}:
let
  flake = builtins.getFlake (toString ./..);
in
flake.packages.${system}
