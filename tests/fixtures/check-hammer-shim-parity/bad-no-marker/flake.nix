# Fixture: flake.nix with NO pkgs.stdenvNoCC.mkDerivation marker — extraction fails.
{
  outputs = _: {
    linpeas = pkgs.someOtherFunction {
      pname = "linpeas";
      version = "1.0";
    };
  };
}
