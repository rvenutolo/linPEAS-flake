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

          linpeas-image = pkgs.dockerTools.buildLayeredImage {
            name = "rvenutolo/linpeas";
            tag = pin.version;

            # nixpkgs 25.05's `buildLayeredImage` only exposes `contents` (not
            # `copyToRoot`). Wrap inputs in a `buildEnv` so `pathsToLink`
            # controls the /bin layering explicitly. Cmd uses the absolute
            # store path of linpeas, unambiguous regardless of /bin layering.
            contents = pkgs.buildEnv {
              name = "image-root";
              paths = [
                pkgs.bashInteractive
                pkgs.coreutils
                linpeas
              ];
              pathsToLink = [ "/bin" ];
            };

            config = {
              # Entrypoint (not Cmd) so `docker run <img> <args>` appends to
              # linpeas rather than replacing it. D9 image-smoke runs
              # `docker run --rm <img> -h` and expects -h to reach linpeas.
              Entrypoint = [ "${linpeas}/bin/linpeas" ];
              Labels = {
                "org.opencontainers.image.source" = "https://github.com/rvenutolo/linPEAS-flake";
                "org.opencontainers.image.description" = "LinPEAS — Linux Privilege Escalation Awesome Script";
                "org.opencontainers.image.licenses" = "MIT";
                "org.opencontainers.image.version" = pin.version;
              };
            };
          };

          linpeas-bundle = pkgs.runCommand "linpeas-bundle-${pin.version}" { } ''
            mkdir -p $out
            install -m 0755 ${linpeas.src} $out/linpeas-bundle.sh
            # Upstream linpeas.sh ships #!/bin/sh; rewrite to #!/usr/bin/env bash so
            # the bundle is portable across systems where /bin/sh is dash/ash.
            ${pkgs.gnused}/bin/sed --in-place '1s|^.*$|#!/usr/bin/env bash|' \
              $out/linpeas-bundle.sh
            chmod 0755 $out/linpeas-bundle.sh
          '';

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
                  # No-op when running inside a nix build sandbox — the
                  # `checks.pre-commit` derivation runs all hooks, but the
                  # script needs `nix flake show` which can't run inside the
                  # sandbox (no daemon, restricted PATH). Local git pre-commit
                  # invocation has full PATH and the check fires normally.
                  if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then
                    exit 0
                  fi
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
          } // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
            inherit linpeas-image linpeas-bundle;
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
