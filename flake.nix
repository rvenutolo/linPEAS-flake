{
  description = "Nix flake wrapping peass-ng/PEASS-ng linpeas.sh for `nix run`";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pre-commit-hooks = {
      # Pinned to a commit compatible with nixos-25.05's lib + pre-commit 4.0.1.
      # Newer git-hooks.nix uses `lib.cli.toCommandLine` (nixpkgs Oct 2025+,
      # absent from 25.05) and emits `language: unsupported` (pre-commit >= 4.4).
      # Renovate / a future nixpkgs bump unblocks moving forward.
      url = "github:cachix/git-hooks.nix/3ff4596663c8cbbffe06d863ee4c950bce2c3b78";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, treefmt-nix, pre-commit-hooks, ... }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = import nixpkgs { inherit system; };
          pin = builtins.fromJSON (builtins.readFile ./linpeas-pin.json);

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
              maintainers = [{
                name = "Rick Venutolo";
                github = "rvenutolo";
                githubId = 12970129;
              }];
            };
          };

          treefmtEval = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;

          preCommitCheck = pre-commit-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              nixpkgs-fmt.enable = true;
              deadnix.enable = true;
              statix.enable = true;
              actionlint.enable = true;
              yamllint.enable = true;
              shellcheck = {
                enable = true;
                # justfile is parsed by `just`, not bash; shellcheck mis-IDs
                # it as shell because the first line looks like a comment.
                excludes = [ "^justfile$" ];
              };
              treefmt = {
                enable = true;
                package = treefmtEval.config.build.wrapper;
              };
              # D6: refuse to commit if README flake-show block is stale.
              # Invokes refresh-flake-show.sh in --check mode — never mutates the
              # working tree, exits 1 on diff. Safe for the autonomous subagent
              # path (no dirty README left behind on failure).
              readme-flake-show-fresh = {
                enable = true;
                name = "readme-flake-show-fresh";
                entry = "${pkgs.writeShellScript "readme-flake-show-fresh" ''
                  set -Eeuo pipefail
                  IFS=$'\n\t'
                  # No-op until both the script and README exist (early-build
                  # tasks land before T12/T14 — the hook activates once both
                  # paths are present and otherwise stays silent).
                  if [[ ! -f scripts/refresh-flake-show.sh || ! -f README.md ]]; then
                    exit 0
                  fi
                  exec ${pkgs.bash}/bin/bash scripts/refresh-flake-show.sh --check
                ''}";
                files = "^(flake\\.nix|flake\\.lock|linpeas-pin\\.json|README\\.md|scripts/refresh-flake-show\\.sh)$";
                pass_filenames = false;
                language = "system";
              };
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

          formatter = treefmtEval.config.build.wrapper;

          checks = {
            formatting = treefmtEval.config.build.check self;
            pre-commit = preCommitCheck;
          };

          devShells.default = pkgs.mkShell {
            inherit (preCommitCheck) shellHook;

            buildInputs = preCommitCheck.enabledPackages ++ (with pkgs; [
              nix
              jq
              gh
              just
              curl
              git
              shellcheck
              shfmt
              nixpkgs-fmt
              deadnix
              statix
              actionlint
              yamllint
              nodePackages.prettier
              pre-commit
              treefmtEval.config.build.wrapper
            ]);
          };
        })
    // {
      overlays.default = _final: prev: {
        inherit (self.packages.${prev.stdenv.hostPlatform.system}) linpeas;
      };
    };
}
