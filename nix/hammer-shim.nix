# Adapter that re-exposes the linpeas derivation (defined in nix/linpeas.nix)
# in the `{ overlays }`-arg shape `nixpkgs-hammer` requires.
#
# Requires NIX_PATH to contain `nixpkgs=<store-path>`. The `nixpkgs-hammering`
# hook in nix/hooks/nix.nix exports `NIX_PATH="nixpkgs=${nixpkgs}"` (the flake's
# pinned nixpkgs input) so `import <nixpkgs>` works without network access,
# including inside `nix flake check`'s sandbox.
#
# `overlays` is accepted (and forwarded) because `nixpkgs-hammer` always passes
# it; the flake already pins nixpkgs so no extra overlays are needed in practice.
{
  overlays ? [ ],
  system ? builtins.currentSystem,
}:
let
  pkgs = import <nixpkgs> { inherit system overlays; };
in
{
  inherit (import ./linpeas.nix { inherit pkgs; }) linpeas;
}
