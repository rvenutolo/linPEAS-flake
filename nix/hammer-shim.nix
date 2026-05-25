# DUPLICATED — keep in sync with the `linpeas = pkgs.stdenvNoCC.mkDerivation`
# block in flake.nix. Drift is enforced by scripts/check-hammer-shim-parity.sh
# (wired as the `hammer-shim-parity` pre-commit hook).
#
# Adapter that re-exposes the linpeas derivation in the
# `{ overlays }`-arg shape `nixpkgs-hammer` requires.
#
# Requires NIX_PATH to contain `nixpkgs=<store-path>`.  The hook entry in
# flake.nix exports `NIX_PATH="nixpkgs=${nixpkgs}"` (the flake's pinned
# nixpkgs input) so the import works without any network access, including
# inside `nix flake check`'s sandbox.
#
# `overlays` is accepted (and ignored) because `nixpkgs-hammer` always
# passes it; the flake already pins nixpkgs and nixpkgs-unstable inputs.
{
  overlays ? [ ],
  system ? builtins.currentSystem,
}:
let
  # `overlays` is forwarded so deadnix does not flag it as unused.
  # nixpkgs-hammer always passes this arg; the flake pins nixpkgs so
  # additional overlays are not needed in practice.
  pkgs = import <nixpkgs> { inherit system overlays; };

  pin =
    let
      raw = builtins.fromJSON (builtins.readFile ../linpeas-pin.json);
    in
    assert (builtins.match "[0-9]{8}-[0-9a-f]{7,40}" raw.version) != null;
    assert (builtins.match "https://github.com/peass-ng/PEASS-ng/releases/download/.*" raw.url) != null;
    raw;

  linpeas = pkgs.stdenvNoCC.mkDerivation {
    pname = "linpeas";
    inherit (pin) version;

    src = pkgs.fetchurl {
      inherit (pin) url hash;
    };

    dontUnpack = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      install -m 0755 $src $out/bin/linpeas
      patchShebangs --host $out/bin/linpeas
      runHook postInstall
    '';

    passthru.pin = pin;

    meta = with pkgs.lib; {
      description = "Linux Privilege Escalation Awesome Script (LinPEAS) from peass-ng";
      homepage = "https://github.com/peass-ng/PEASS-ng";
      license = licenses.mit;
      platforms = platforms.unix;
      mainProgram = "linpeas";
      maintainers = [
        {
          name = "Rick Venutolo";
          github = "rvenutolo";
          githubId = 12970129;
        }
      ];
    };
  };
in
{
  inherit linpeas;
}
