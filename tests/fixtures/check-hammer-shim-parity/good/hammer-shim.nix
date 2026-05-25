# Minimal fixture: hammer-shim.nix with identical pkgs.stdenvNoCC.mkDerivation block.
{
  overlays ? [ ],
  system ? builtins.currentSystem,
}:
let
  pkgs = import <nixpkgs> { inherit system overlays; };
  linpeas = pkgs.stdenvNoCC.mkDerivation {
    pname = "linpeas";
    version = "1.0";
    dontUnpack = true;
    installPhase = ''
      mkdir -p $out/bin
      install -m 0755 $src $out/bin/linpeas
    '';
  };
in
{
  inherit linpeas;
}
