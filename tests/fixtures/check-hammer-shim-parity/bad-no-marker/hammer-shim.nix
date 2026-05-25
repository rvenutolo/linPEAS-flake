# Fixture: hammer-shim.nix with NO pkgs.stdenvNoCC.mkDerivation marker — extraction fails.
{
  overlays ? [ ],
  system ? builtins.currentSystem,
}:
let
  pkgs = import <nixpkgs> { inherit system overlays; };
  linpeas = pkgs.someOtherFunction {
    pname = "linpeas";
    version = "1.0";
  };
in
{
  inherit linpeas;
}
