{
  perSystem =
    { pkgs, ... }:
    {
      # `pkgs` (stable) arrives as a perSystem arg — DO NOT re-import it.
      # nix/linpeas.nix parses and shape-asserts the pin and builds the
      # derivation; both `pin` and `linpeas` are exposed to every module.
      _module.args = import ./linpeas.nix { inherit pkgs; };
    };
}
