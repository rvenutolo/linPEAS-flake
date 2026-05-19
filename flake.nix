{
  description = "Nix flake wrapping peass-ng/PEASS-ng linpeas.sh for `nix run`";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pre-commit-hooks = {
      url = "github:cachix/git-hooks.nix/61ab0e80d9c7ab14c256b5b453d8b3fb0189ba0a";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, treefmt-nix, pre-commit-hooks, ... }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = import nixpkgs { inherit system; };
          # Read pin file with eager invariant checks. Anything outside the
          # expected upstream shape (peass-ng release URL, YYYYMMDD-<hex> tag
          # format) fails flake eval immediately — pin.version is interpolated
          # into derivation names, docker tags, and OCI labels downstream, so
          # an unvalidated value is a supply-chain footgun.
          pin =
            let
              raw = builtins.fromJSON (builtins.readFile ./linpeas-pin.json);
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
              # linpeas invokes grep/sed/awk/find/ps internally for most of its
              # checks. Ship them so the image is actually useful for its
              # intended use cases (container audit, CI image scanning,
              # forensics on mounted captured filesystems, and host audit when
              # launched with host namespaces + bind mount). See
              # docs/install/docker.md for the use-case framing.
              paths = [
                pkgs.bashInteractive
                pkgs.coreutils
                pkgs.gnugrep
                pkgs.gnused
                pkgs.gawk
                pkgs.findutils
                pkgs.procps
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
            # Guard against empty or shebang-less upstream blob. Without
            # this, sed's `1s|^.*$|...|` either no-ops on an empty file or
            # mangles a single-line binary blob. Failing here surfaces the
            # upstream weirdness loudly rather than letting a malformed
            # bundle slip through smoke tests.
            if ! head -n 1 $out/linpeas-bundle.sh | ${pkgs.gnugrep}/bin/grep --quiet '^#!'; then
              echo "upstream linpeas.sh has no shebang on line 1" >&2
              exit 1
            fi
            # Upstream linpeas.sh ships #!/bin/sh; rewrite to #!/usr/bin/env bash so
            # the bundle is portable across systems where /bin/sh is dash/ash.
            ${pkgs.gnused}/bin/sed --in-place '1s|^.*$|#!/usr/bin/env bash|' \
              $out/linpeas-bundle.sh
            chmod 0755 $out/linpeas-bundle.sh
          '';

          site = pkgs.stdenv.mkDerivation {
            pname = "linpeas-flake-site";
            inherit (pin) version;
            src = ./.;
            nativeBuildInputs = with pkgs.python3Packages; [
              mkdocs-material
              mkdocs-macros
            ];
            buildPhase = ''
              runHook preBuild
              if [ ! -f docs/_data/dashboard.yml ]; then
                echo "ERROR: docs/_data/dashboard.yml missing. Run 'just site-data' first or use 'just site-dev'." >&2
                exit 1
              fi
              mkdocs build --strict --site-dir $out/share/site
              runHook postBuild
            '';
            dontInstall = true;
          };

          treefmtEval = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;

          preCommitCheck = pre-commit-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              nixpkgs-fmt.enable = true;
              deadnix.enable = true;
              statix.enable = true;
              actionlint.enable = true;
              # Doc-quality hooks — mirror the CI lint required-check set
              # so author catches issues before push.
              markdownlint = {
                enable = true;
                # Excludes mirror the CI markdownlint-cli2-action globs:
                # docs/dashboard.md + docs/releases.md are mkdocs-macros
                # templated and not raw markdown; docs/_data/* is the
                # generated dashboard YAML.
                excludes = [
                  "^docs/dashboard\\.md$"
                  "^docs/releases\\.md$"
                  "^docs/_data/"
                ];
              };
              typos.enable = true;
              editorconfig-checker.enable = true;
              # `commitizen check` enforces Conventional Commits on the
              # commit message — Conventional-Commits parity with the CI
              # `commitlint` job, using a Python tool packaged in nixpkgs.
              commitizen.enable = true;
              zizmor = {
                enable = true;
                # Older zizmor versions (e.g. 1.8.0 from nixos-25.05) exit
                # non-zero on any finding including informational. Newer
                # versions default to `--min-severity=low`; mirror that
                # here so the hook is consistent across nixpkgs bumps.
                entry = "${pkgs.zizmor}/bin/zizmor --min-severity=low";
              };
              yamllint.enable = true;
              shellcheck = {
                enable = true;
                # justfile is parsed by `just`, not bash; shellcheck
                # misidentifies it as shell because the first line looks
                # like a comment.
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
              # Belt-and-braces backup to the GitHub-side
              # `sha_pinning_required` setting. Mirrors the NIX_BUILD_TOP guard used
              # by readme-flake-show-fresh so nix flake check doesn't fail
              # inside the sandbox where the script can't reach .github/.
              uses-sha-pinned = {
                enable = true;
                name = "uses-sha-pinned";
                entry = "${pkgs.writeShellScript "uses-sha-pinned-hook" ''
                  set -Eeuo pipefail
                  IFS=$'\n\t'
                  if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
                  exec ${pkgs.bash}/bin/bash scripts/check-uses-sha-pinned.sh
                ''}";
                files = "^(\\.github/workflows/.*\\.ya?ml|\\.github/actions/.*\\.ya?ml|scripts/check-uses-sha-pinned\\.sh)$";
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
            inherit linpeas-image linpeas-bundle site;
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
              yq-go
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
              zizmor
              yamllint
              nodePackages.prettier
              pre-commit
              treefmtEval.config.build.wrapper
              python3Packages.mkdocs-material
              python3Packages.mkdocs-macros
              lychee
            ]);
          };
        })
    // {
      overlays.default = _final: prev: {
        inherit (self.packages.${prev.stdenv.hostPlatform.system}) linpeas;
      };
    };
}
