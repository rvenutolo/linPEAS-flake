{
  description = "Nix flake wrapping peass-ng/PEASS-ng linpeas.sh for `nix run`";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        pin = builtins.fromJSON (builtins.readFile ./linpeas-pin.json);

        linpeas = pkgs.stdenvNoCC.mkDerivation {
          pname = "linpeas";
          version = pin.version;

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
            maintainers = [{
              name = "Rick Venutolo";
              github = "rvenutolo";
              githubId = 12970129;
            }];
          };
        };
      in
      {
        packages = {
          inherit linpeas;
          default = linpeas;
        };

        apps = {
          linpeas = {
            type = "app";
            program = "${linpeas}/bin/linpeas";
            meta = {
              description = "Linux Privilege Escalation Awesome Script (LinPEAS) from peass-ng";
            };
          };
          default = self.apps.${system}.linpeas;
        };
      })
    // {
      overlays.default = final: prev: {
        linpeas = self.packages.${prev.stdenv.hostPlatform.system}.linpeas;
      };
    };
}
