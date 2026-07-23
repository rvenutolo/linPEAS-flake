# The canonical linpeas derivation, imported by both nix/pin.nix (the flake's
# `linpeas` output) and nix/hammer-shim.nix.
#
# It lives in a plain importable file — not a flake output — because
# nix/hammer-shim.nix is evaluated by `nixpkgs-hammer` inside the
# `nix flake check` sandbox, where `builtins.getFlake` cannot reach the flake's
# own outputs and github.com is unreachable. A plain `import` needs neither.
#
# The pin is parsed and shape-asserted here so every consumer gets the same
# eager invariant check: pin.version is interpolated into derivation names,
# docker tags, and OCI labels downstream, so an out-of-shape value must fail
# flake eval immediately rather than propagate.
{
  pkgs,
  pinFile ? ../linpeas-pin.json,
}:
let
  pin =
    let
      raw = builtins.fromJSON (builtins.readFile pinFile);
    in
    assert (builtins.match "[0-9]{8}-[0-9a-f]{7,40}" raw.version) != null;
    assert (builtins.match "https://github.com/peass-ng/PEASS-ng/releases/download/.*" raw.url) != null;
    # peass-ng release URLs embed the tag as a path segment
    # (.../download/<tag>/linpeas.sh). Require version to be that segment so a
    # hand-edited pin cannot declare one version while fetching another
    # release's artifact — the derivation name, docker tag, and OCI version
    # label would otherwise advertise content that does not match.
    assert (builtins.match ".*/${raw.version}/.*" raw.url) != null;
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
  inherit pin linpeas;
}
