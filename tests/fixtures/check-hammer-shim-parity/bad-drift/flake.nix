# Fixture: flake.nix derivation block.
{
  outputs = _: {
    linpeas = pkgs.stdenvNoCC.mkDerivation {
      pname = "linpeas";
      version = "1.0";
      dontUnpack = true;
      installPhase = ''
        mkdir -p $out/bin
        install -m 0755 $src $out/bin/linpeas
      '';
    };
  };
}
