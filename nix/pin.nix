{
  perSystem =
    { pkgs, ... }:
    let
      # `pkgs` (stable) and `pkgs-unstable` arrive as args — DO NOT re-import them.
      # Read pin file with eager invariant checks. Anything outside the
      # expected upstream shape (peass-ng release URL, YYYYMMDD-<hex> tag
      # format) fails flake eval immediately — pin.version is interpolated
      # into derivation names, docker tags, and OCI labels downstream, so
      # an unvalidated value is a supply-chain footgun.
      pin =
        let
          raw = builtins.fromJSON (builtins.readFile ../linpeas-pin.json);
        in
        assert (builtins.match "[0-9]{8}-[0-9a-f]{7,40}" raw.version) != null;
        assert (builtins.match "https://github.com/peass-ng/PEASS-ng/releases/download/.*" raw.url) != null;
        raw;

      # DUPLICATED into nix/hammer-shim.nix (sandbox cannot use getFlake).
      # Parity enforced by scripts/check-hammer-shim-parity.sh.
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
      _module.args = { inherit pin linpeas; };
    };
}
