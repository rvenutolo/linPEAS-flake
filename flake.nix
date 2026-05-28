{
  description = "Nix flake wrapping peass-ng/PEASS-ng linpeas.sh for `nix run`";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    pre-commit-hooks = {
      url = "github:cachix/git-hooks.nix/61ab0e80d9c7ab14c256b5b453d8b3fb0189ba0a";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      flake-utils,
      treefmt-nix,
      pre-commit-hooks,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        pkgs-unstable = import nixpkgs-unstable { inherit system; };
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
            # linpeas rather than replacing it. The image-smoke CI job
            # runs `docker run --rm <img> -h` and expects -h to reach
            # linpeas.
            Entrypoint = [ "${linpeas}/bin/linpeas" ];
            Labels = {
              "org.opencontainers.image.source" = "https://github.com/rvenutolo/linPEAS-flake";
              "org.opencontainers.image.description" = "LinPEAS — Linux Privilege Escalation Awesome Script";
              "org.opencontainers.image.licenses" = "MIT";
              "org.opencontainers.image.version" = pin.version;
              # Wrapper-repo commit SHA at build time. Build-provenance
              # attestation already binds the image to this commit, but
              # the label is readable via `docker inspect` without
              # `gh attestation verify` round-tripping. Falls back to
              # `dirtyRev` for uncommitted local builds.
              "org.opencontainers.image.revision" = self.rev or self.dirtyRev or "unknown";
            };
          };
        };

        site = pkgs-unstable.stdenv.mkDerivation {
          pname = "linpeas-flake-site";
          inherit (pin) version;
          src = ./.;
          nativeBuildInputs = with pkgs-unstable.python3Packages; [
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

        treefmtEval = treefmt-nix.lib.evalModule pkgs-unstable ./treefmt.nix;

        preCommitHooks = {
          nixfmt = {
            enable = true;
            description = "Nix file formatting.";
          };
          deadnix = {
            enable = true;
            description = "Unused Nix bindings.";
          };
          statix = {
            enable = true;
            description = "Nix anti-pattern lint.";
          };
          # nixpkgs-hammering complements statix: statix catches anti-patterns
          # (with-scope abuse, redundant let), hammering catches nixpkgs idiom
          # misuse on derivations (meta fields, fetcher idioms, build phases).
          # Scoped `files:` so hammer only fires when the flake derivation or
          # its inputs change — hammer evaluates a full nixpkgs overlay and is
          # not cheap.
          nixpkgs-hammering = {
            enable = true;
            name = "nixpkgs-hammering";
            description = "nixpkgs idiom checker for the linpeas derivation.";
            # NIX_PATH exports the pinned nixpkgs store path so the shim can
            # `import <nixpkgs>` without network access — critical for running
            # inside `nix flake check`'s sandbox where github.com is unreachable.
            entry = "${pkgs-unstable.writeShellScript "nixpkgs-hammering-hook" ''
              export NIX_PATH="nixpkgs=${nixpkgs}"
              exec ${pkgs-unstable.nixpkgs-hammering}/bin/nixpkgs-hammer \
                -f nix/hammer-shim.nix linpeas
            ''}";
            files = "^(flake\\.nix|flake\\.lock|linpeas-pin\\.json|nix/hammer-shim\\.nix)$";
            pass_filenames = false;
            language = "system";
          };
          hammer-shim-parity = {
            enable = true;
            name = "hammer-shim-parity";
            description = "nix/hammer-shim.nix linpeas derivation matches flake.nix.";
            entry = "${pkgs-unstable.writeShellScript "hammer-shim-parity-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-hammer-shim-parity.sh
            ''}";
            files = "^(flake\\.nix|nix/hammer-shim\\.nix|scripts/check-hammer-shim-parity\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          actionlint = {
            enable = true;
            description = "GitHub Actions workflow syntax (shellcheck pinned).";
            entry = "${actionlintWrapped}/bin/actionlint";
          };
          # Doc-quality hooks — mirror the CI lint required-check set
          # so author catches issues before push.
          markdownlint = {
            enable = true;
            description = "Markdown style + structure.";
            # Excludes mirror the CI markdownlint-cli2-action globs:
            # docs/dashboard.md + docs/releases.md are mkdocs-macros
            # templated and not raw markdown; docs/_data/* is the
            # generated dashboard YAML. tests/fixtures/* contains
            # intentionally-invalid markdown for test harnesses.
            excludes = [
              "^docs/dashboard\\.md$"
              "^docs/releases\\.md$"
              "^docs/_data/"
              "^tests/fixtures/"
              # Generator-owned by git-cliff; rule violations there
              # come from cliff's template, not author choice.
              "^CHANGELOG\\.md$"
            ];
          };
          typos = {
            enable = true;
            description = "Spell-check across the repo.";
          };
          editorconfig-checker = {
            enable = true;
            description = ".editorconfig compliance (charset, line endings, trailing whitespace, final newline).";
          };
          # Conventional Commits enforcement: `commitlint` with the
          # `@commitlint/config-conventional` ruleset from
          # `.commitlintrc.yml`. Parity with the CI `commitlint` job —
          # same engine, same config, so any rule (subject type-enum,
          # body-max-line-length, header-max-length, etc.) fails
          # locally instead of after push. Replaces the older
          # `commitizen.enable` hook, which validated the subject only.
          commitlint = {
            enable = true;
            name = "commitlint";
            description = "Commit message satisfies Conventional Commits (CI parity via .commitlintrc.yml).";
            entry = "${pkgs-unstable.commitlint}/bin/commitlint --config .commitlintrc.yml --edit";
            stages = [ "commit-msg" ];
            language = "system";
            pass_filenames = true;
          };
          zizmor = {
            enable = true;
            description = "GitHub Actions security audit.";
            # Older zizmor versions (e.g. 1.8.0 from nixos-25.05) exit
            # non-zero on any finding including informational. Newer
            # versions default to `--min-severity=low`; mirror that
            # here so the hook is consistent across nixpkgs bumps.
            entry = "${pkgs-unstable.zizmor}/bin/zizmor --min-severity=low";
          };
          yamllint = {
            enable = true;
            description = "YAML style.";
          };
          shellcheck = {
            enable = true;
            description = "Shell-script static analysis.";
            # justfile is parsed by `just`, not bash; shellcheck
            # misidentifies it as shell because the first line looks
            # like a comment.
            excludes = [ "^justfile$" ];
          };
          treefmt = {
            enable = true;
            description = "Multi-language formatter aggregator (shfmt, prettier, etc).";
            package = treefmtEval.config.build.wrapper;
          };
          # Refuse to commit if the flake-show block in docs/reference/flake-outputs.md
          # is stale. Invokes refresh-flake-show.sh in --check mode — never mutates the
          # working tree, exits 1 on diff. Safe for the autonomous subagent
          # path (no dirty doc left behind on failure).
          flake-show-fresh = {
            enable = true;
            name = "flake-show-fresh";
            description = "flake-show block in docs/reference/flake-outputs.md matches current flake outputs.";
            entry = "${pkgs-unstable.writeShellScript "flake-show-fresh" ''
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
              # No-op until both the script and the doc exist; the hook
              # activates once both paths are present and otherwise stays silent.
              if [[ ! -f scripts/refresh-flake-show.sh || ! -f docs/reference/flake-outputs.md ]]; then
                exit 0
              fi
              exec ${pkgs-unstable.bash}/bin/bash scripts/refresh-flake-show.sh --check
            ''}";
            files = "^(flake\\.nix|flake\\.lock|linpeas-pin\\.json|docs/reference/flake-outputs\\.md|scripts/refresh-flake-show\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          # Refuse to commit if the pre-commit hook table in docs/development/git.md
          # is stale relative to the flake hook manifest. Invokes
          # refresh-precommit-table.sh in --check mode — never mutates the
          # working tree, exits 1 on diff.
          just-recipes-fresh = {
            enable = true;
            name = "just-recipes-fresh";
            description = "just-recipes blocks in README.md and docs/reference/just-recipes.md match the justfile.";
            entry = "${pkgs-unstable.writeShellScript "just-recipes-fresh" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              export PATH="${pkgs-unstable.just}/bin:$PATH"
              exec ${pkgs-unstable.bash}/bin/bash scripts/refresh-just-recipes.sh --check
            ''}";
            files = "^(justfile|README\\.md|docs/reference/just-recipes\\.md|scripts/refresh-just-recipes\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          treefmt-config-fresh = {
            enable = true;
            name = "treefmt-config-fresh";
            description = "treefmt-config block in docs/reference/treefmt-config.md matches the evaluated treefmt config.";
            entry = "${pkgs-unstable.writeShellScript "treefmt-config-fresh" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              # No-op when running inside a nix build sandbox — the script
              # shells out to `nix eval` which can't run inside the sandbox.
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              if [[ ! -f scripts/refresh-treefmt-config.sh || ! -f docs/reference/treefmt-config.md ]]; then
                exit 0
              fi
              export PATH="${pkgs-unstable.jq}/bin:${pkgs-unstable.gawk}/bin:${treefmtEval.config.build.wrapper}/bin:$PATH"
              exec ${pkgs-unstable.bash}/bin/bash scripts/refresh-treefmt-config.sh --check
            ''}";
            files = "^(treefmt\\.nix|flake\\.nix|flake\\.lock|docs/reference/treefmt-config\\.md|scripts/refresh-treefmt-config\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          scripts-reference-fresh = {
            enable = true;
            name = "scripts-reference-fresh";
            description = "docs/reference/scripts.md matches in-script annotations.";
            entry = "${pkgs-unstable.writeShellScript "scripts-reference-fresh" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              export PATH="${pkgs-unstable.jq}/bin:${pkgs-unstable.gawk}/bin:${treefmtEval.config.build.wrapper}/bin:$PATH"
              exec ${pkgs-unstable.bash}/bin/bash scripts/refresh-scripts-reference.sh --check
            ''}";
            files = "^(scripts/.*\\.sh|scripts/_script_docs\\.awk|docs/reference/scripts\\.md)$";
            pass_filenames = false;
            language = "system";
          };
          precommit-table-fresh = {
            enable = true;
            name = "precommit-table-fresh";
            description = "Hook table in docs/development/git.md matches the flake hook manifest.";
            entry = "${pkgs-unstable.writeShellScript "precommit-table-fresh" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              exec ${pkgs-unstable.bash}/bin/bash scripts/refresh-precommit-table.sh --check
            ''}";
            files = "^(flake\\.nix|docs/development/git\\.md|scripts/refresh-precommit-table\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          ci-dag-fresh = {
            enable = true;
            name = "ci-dag-fresh";
            description = "docs/architecture/ci-dag.md matches .github/workflows/ci.yml needs graph.";
            entry = "${pkgs-unstable.writeShellScript "ci-dag-fresh" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              export PATH="${pkgs-unstable.jq}/bin:${pkgs-unstable.yq-go}/bin:${treefmtEval.config.build.wrapper}/bin:$PATH"
              exec ${pkgs-unstable.bash}/bin/bash scripts/refresh-ci-dag.sh --check
            ''}";
            files = "^(\\.github/workflows/ci\\.yml|docs/_data/ci-check-categories\\.yml|docs/architecture/ci-dag\\.md|scripts/refresh-ci-dag\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          ci-summary-fresh = {
            enable = true;
            name = "ci-summary-fresh";
            description = "README CI summary matches required-checks.md and the category map.";
            entry = "${pkgs-unstable.writeShellScript "ci-summary-fresh" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
              exec ${pkgs-unstable.bash}/bin/bash scripts/refresh-ci-summary.sh --check
            ''}";
            files = "^(README\\.md|docs/security/required-checks\\.md|docs/_data/ci-check-categories\\.yml|scripts/refresh-ci-summary\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          enforcement-matrix-fresh = {
            enable = true;
            name = "enforcement-matrix-fresh";
            description = "docs/security/enforcement-matrix.md matches the annotated invariant index and real enforcers.";
            entry = "${pkgs-unstable.writeShellScript "enforcement-matrix-fresh" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              export PATH="${pkgs-unstable.jq}/bin:${pkgs-unstable.yq-go}/bin:$PATH"
              exec ${pkgs-unstable.bash}/bin/bash scripts/refresh-enforcement-matrix.sh --check
            ''}";
            files = "^(docs/invariant-index\\.md|docs/security/enforcement-matrix\\.md|scripts/check-.*\\.sh|scripts/refresh-enforcement-matrix\\.sh|\\.github/workflows/ci\\.yml|flake\\.nix)$";
            pass_filenames = false;
            language = "system";
          };
          # Belt-and-braces backup to the GitHub-side
          # `sha_pinning_required` setting. Mirrors the NIX_BUILD_TOP guard used
          # by flake-show-fresh so nix flake check doesn't fail
          # inside the sandbox where the script can't reach .github/.
          uses-sha-pinned = {
            enable = true;
            name = "uses-sha-pinned";
            description = "Every uses: reference is SHA-pinned.";
            entry = "${pkgs-unstable.writeShellScript "uses-sha-pinned-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-uses-sha-pinned.sh
            ''}";
            files = "^(\\.github/workflows/.*\\.ya?ml|\\.github/actions/.*\\.ya?ml|scripts/check-uses-sha-pinned\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          # Asserts every job in .github/workflows/*.yml starts with
          # step-security/harden-runner as its first step. Belt-and-braces
          # lint mirrors the trust-model invariant; eBPF monitor must
          # install before any I/O.
          harden-runner-first = {
            enable = true;
            name = "harden-runner-first";
            description = "Every workflow job's first step is step-security/harden-runner.";
            entry = "${pkgs-unstable.writeShellScript "harden-runner-first-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-harden-runner-first.sh
            ''}";
            files = "^(\\.github/workflows/.*\\.ya?ml|scripts/check-harden-runner-first\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          # Strict least-privilege lint: every workflow's top-level
          # permissions: must be `{}` and every job must declare its
          # own scopes. See docs/security/min-permissions.md.
          min-permissions = {
            enable = true;
            name = "min-permissions";
            description = "Top-level workflow permissions empty; each job declares its own scopes.";
            entry = "${pkgs-unstable.writeShellScript "min-permissions-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-min-permissions.sh
            ''}";
            files = "^(\\.github/workflows/.*\\.ya?ml|scripts/check-min-permissions\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          # Every job under .github/workflows/ declares an explicit
          # timeout-minutes. The default is 6 hours; without an
          # explicit cap a hung job burns the runner budget and stalls
          # the merge queue. See docs/security/workflow-hardening.md.
          job-timeout-minutes = {
            enable = true;
            name = "job-timeout-minutes";
            description = "Every workflow job declares an explicit timeout-minutes.";
            entry = "${pkgs-unstable.writeShellScript "job-timeout-minutes-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-job-timeout-minutes.sh
            ''}";
            files = "^(\\.github/workflows/.*\\.ya?ml|scripts/check-job-timeout-minutes\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          # Every workflow declares a top-level concurrency.group so
          # parallel runs on the same ref don't pile up. Without one,
          # cron and back-to-back PR pushes can spawn racing runs that
          # touch shared remote state. See docs/security/workflow-hardening.md.
          workflow-concurrency = {
            enable = true;
            name = "workflow-concurrency";
            description = "Every workflow declares a top-level concurrency.group.";
            entry = "${pkgs-unstable.writeShellScript "workflow-concurrency-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-workflow-concurrency.sh
            ''}";
            files = "^(\\.github/workflows/.*\\.ya?ml|scripts/check-workflow-concurrency\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          # Every actions/checkout step sets persist-credentials: false
          # so GITHUB_TOKEN isn't written into .git/config and left on
          # disk for later steps to read. See
          # docs/security/workflow-hardening.md.
          checkout-persist-credentials = {
            enable = true;
            name = "checkout-persist-credentials";
            description = "Every actions/checkout sets with.persist-credentials: false.";
            entry = "${pkgs-unstable.writeShellScript "checkout-persist-credentials-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-checkout-persist-credentials.sh
            ''}";
            files = "^(\\.github/workflows/.*\\.ya?ml|scripts/check-checkout-persist-credentials\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          # Every actions/upload-artifact step sets if-no-files-found:
          # error so a broken path: glob fails the job instead of
          # silently uploading an empty artifact. See
          # docs/security/workflow-hardening.md.
          upload-artifact-strict = {
            enable = true;
            name = "upload-artifact-strict";
            description = "Every actions/upload-artifact sets with.if-no-files-found: error.";
            entry = "${pkgs-unstable.writeShellScript "upload-artifact-strict-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-upload-artifact-strict.sh
            ''}";
            files = "^(\\.github/workflows/.*\\.ya?ml|scripts/check-upload-artifact-strict\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          # Every pull_request: / push: trigger explicitly declares
          # branches: [main]. Implicit all-branches triggers waste
          # runner minutes on stale topic branches. See
          # docs/security/workflow-hardening.md.
          workflow-on-branches = {
            enable = true;
            name = "workflow-on-branches";
            description = "pull_request: and push: declare branches: [main] explicitly.";
            entry = "${pkgs-unstable.writeShellScript "workflow-on-branches-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-workflow-on-branches.sh
            ''}";
            files = "^(\\.github/workflows/.*\\.ya?ml|scripts/check-workflow-on-branches\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          # Hard-ban the pull_request_target trigger. Running the base
          # ref's workflow with full secret scope while operating on
          # head-ref code is the canonical Actions privilege-escalation
          # footgun. See docs/security/workflow-hardening.md.
          pull-request-target-absent = {
            enable = true;
            name = "pull-request-target-absent";
            description = "No workflow uses the pull_request_target trigger.";
            entry = "${pkgs-unstable.writeShellScript "pull-request-target-absent-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-pull-request-target-absent.sh
            ''}";
            files = "^(\\.github/workflows/.*\\.ya?ml|scripts/check-pull-request-target-absent\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          # Every scripts/*.sh starts with #!/usr/bin/env bash and
          # contains set -Eeuo pipefail. See docs/security/workflow-hardening.md.
          script-shebang-pipefail = {
            enable = true;
            name = "script-shebang-pipefail";
            description = "Every scripts/*.sh has portable shebang + set -Eeuo pipefail.";
            entry = "${pkgs-unstable.writeShellScript "script-shebang-pipefail-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-script-shebang-pipefail.sh
            ''}";
            files = "^scripts/.*\\.sh$";
            pass_filenames = false;
            language = "system";
          };
          # Every scripts/check-*.sh has tests/check-*.test.sh and
          # vice versa. See docs/security/workflow-hardening.md.
          script-has-test = {
            enable = true;
            name = "script-has-test";
            description = "Every scripts/check-*.sh paired with tests/check-*.test.sh.";
            entry = "${pkgs-unstable.writeShellScript "script-has-test-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-script-has-test.sh
            ''}";
            files = "^(scripts/check-.*\\.sh|tests/check-.*\\.test\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          # Every ci.yml job either in ci-check-categories.yml or
          # EXEMPT, and every category entry points at a real job.
          # See docs/security/workflow-hardening.md.
          ci-job-in-summary = {
            enable = true;
            name = "ci-job-in-summary";
            description = "ci.yml jobs cross-checked against docs/_data/ci-check-categories.yml.";
            entry = "${pkgs-unstable.writeShellScript "ci-job-in-summary-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-ci-job-in-summary.sh
            ''}";
            files = "^(\\.github/workflows/ci\\.yml|docs/_data/ci-check-categories\\.yml|scripts/check-ci-job-in-summary\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          # Every multi-line run: block starts with set -Eeuo pipefail.
          # See docs/security/workflow-hardening.md.
          run-block-strict = {
            enable = true;
            name = "run-block-strict";
            description = "Multi-line run: blocks start with set -Eeuo pipefail.";
            entry = "${pkgs-unstable.writeShellScript "run-block-strict-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-run-block-strict.sh
            ''}";
            files = "^(\\.github/workflows/.*\\.ya?ml|scripts/check-run-block-strict\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          # Release-grade jobs include the fork-guard if: clause.
          # See docs/security/workflow-hardening.md.
          fork-guard-release = {
            enable = true;
            name = "fork-guard-release";
            description = "Release-grade jobs include github.repository fork guard.";
            entry = "${pkgs-unstable.writeShellScript "fork-guard-release-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              export PATH="${pkgs-unstable.yq-go}/bin:$PATH"
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-fork-guard-release.sh
            ''}";
            files = "^(\\.github/workflows/.*\\.ya?ml|scripts/check-fork-guard-release\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          # Every gh attestation verify invocation passes --repo.
          # See docs/security/verification.md.
          gh-attestation-repo = {
            enable = true;
            name = "gh-attestation-repo";
            description = "gh attestation verify pins --repo rvenutolo/linPEAS-flake.";
            entry = "${pkgs-unstable.writeShellScript "gh-attestation-repo-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-gh-attestation-repo.sh
            ''}";
            files = "^(\\.github/workflows/.*\\.ya?ml|scripts/.*\\.sh|docs/.*\\.md|README\\.md|SECURITY\\.md)$";
            pass_filenames = false;
            language = "system";
          };
          # cosign verify pins identity + OIDC issuer.
          # See docs/security/verification.md.
          cosign-identity-pinned = {
            enable = true;
            name = "cosign-identity-pinned";
            description = "cosign verify pins --certificate-identity[-regexp] + --certificate-oidc-issuer.";
            entry = "${pkgs-unstable.writeShellScript "cosign-identity-pinned-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-cosign-identity-pinned.sh
            ''}";
            files = "^(\\.github/workflows/.*\\.ya?ml|scripts/.*\\.sh|docs/.*\\.md|README\\.md|SECURITY\\.md)$";
            pass_filenames = false;
            language = "system";
          };
          # Ban unpinned nix run nixpkgs#<pkg> invocations.
          # See docs/security/workflow-hardening.md.
          nix-run-pinned = {
            enable = true;
            name = "nix-run-pinned";
            description = "No unpinned nix run nixpkgs#<pkg>; use nix shell .#<pkg> or pin a rev.";
            entry = "${pkgs-unstable.writeShellScript "nix-run-pinned-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-nix-run-pinned.sh
            ''}";
            files = "^(\\.github/workflows/.*\\.ya?ml|scripts/.*\\.sh|docs/.*\\.md|README\\.md|SECURITY\\.md)$";
            pass_filenames = false;
            language = "system";
          };
          # Schema-shape validation for repo config. Catches typoed
          # keys, wrong-type values, and upstream-removed fields that
          # per-tool linters miss. NIX_BUILD_TOP guard skips inside
          # the flake-check sandbox where network fetches for the
          # pinned SchemaStore schema would fail.
          check-jsonschema = {
            enable = true;
            name = "check-jsonschema";
            description = "Schema-shape validation of repo config (renovate.json, workflows, actions).";
            entry = "${pkgs-unstable.writeShellScript "check-jsonschema-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              export PATH="${pkgs-unstable.check-jsonschema}/bin:$PATH"
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-jsonschema.sh
            ''}";
            files = "^(renovate\\.json|\\.markdownlint\\.json|\\.github/workflows/.*\\.ya?ml|\\.github/actions/.*\\.ya?ml|scripts/check-jsonschema\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          # Validates renovate.json against the upstream Renovate
          # config schema. Catches typoed keys / wrong-type values
          # before they ship and surface as a Dependency Dashboard
          # error after merge. NIX_BUILD_TOP guard skips inside the
          # flake-check sandbox where the validator's network probes
          # would fail.
          renovate-config-validator = {
            enable = true;
            name = "renovate-config-validator";
            description = "Validate renovate.json against the upstream Renovate config schema.";
            entry = "${pkgs-unstable.writeShellScript "renovate-config-validator-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              export PATH="${pkgs-unstable.renovate}/bin:$PATH"
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-renovate-config-validator.sh
            ''}";
            files = "^(renovate\\.json|scripts/check-renovate-config-validator\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          # Asserts only scripts/bump-linpeas.sh mutates
          # linpeas-pin.json — the release-on-bump trigger contract
          # depends on this isolation invariant.
          pin-diff-isolated = {
            enable = true;
            name = "pin-diff-isolated";
            description = "Only scripts/bump-linpeas.sh mutates linpeas-pin.json.";
            entry = "${pkgs-unstable.writeShellScript "pin-diff-isolated-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-pin-diff-isolated.sh
            ''}";
            files = "^(scripts/.*\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          # Asserts every `gh api` / `api.github.com` call in
          # scripts/*.sh passes an explicit `X-GitHub-Api-Version`
          # header. Without it, GitHub treats the client as
          # unversioned and may auto-promote it to a future API
          # version whose response shape differs from what the
          # script parses.
          gh-api-version-header = {
            enable = true;
            name = "gh-api-version-header";
            description = "Every gh api / api.github.com call in scripts passes an X-GitHub-Api-Version header.";
            entry = "${pkgs-unstable.writeShellScript "gh-api-version-header-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-gh-api-version-header.sh
            ''}";
            files = "^(scripts/.*\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          # Catches divergence between the SHA in flake.nix's
          # pre-commit-hooks input URL and the locked.rev in flake.lock.
          # Fires when either file changes. NIX_BUILD_TOP guard skips
          # inside the flake-check sandbox where git is not available.
          pre-commit-hooks-sha-parity = {
            enable = true;
            name = "pre-commit-hooks-sha-parity";
            description = "The pre-commit-hooks input SHA in flake.nix matches flake.lock locked.rev.";
            entry = "${pkgs-unstable.writeShellScript "pre-commit-hooks-sha-parity-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-pre-commit-hooks-sha-parity.sh
            ''}";
            files = "^(flake\\.nix|flake\\.lock|scripts/check-pre-commit-hooks-sha-parity\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          # Asserts every entry in docs/invariant-index.md resolves
          # to an existing docs/ file, and every docs/**/*.md (minus
          # EXEMPT and the index itself) has an entry.
          check-orphan-invariants = {
            enable = true;
            name = "check-orphan-invariants";
            description = "Every docs/ file has an invariant-index entry and vice versa.";
            entry = "${pkgs-unstable.writeShellScript "check-orphan-invariants-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-orphan-invariants.sh
            ''}";
            files = "^(docs/invariant-index\\.md|docs/.*\\.md|scripts/check-orphan-invariants\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          # Canary: assert actionlint's embedded shellcheck
          # integration is wired. Runs the wrapper-pinned actionlint
          # binary against tests/fixtures/actionlint-shellcheck-smoke.yml
          # (which has a planted SC2086) and fails if the finding is
          # not surfaced. Guards against silent regression of the
          # shellcheck pin in actionlintWrapped. See
          # docs/actionlint-embedded-linters.md.
          actionlint-shellcheck-active = {
            enable = true;
            name = "actionlint-shellcheck-active";
            description = "actionlint shellcheck integration canary.";
            entry = "${pkgs-unstable.writeShellScript "check-actionlint-shellcheck-active-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              export PATH="${actionlintWrapped}/bin:$PATH"
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-actionlint-shellcheck-active.sh
            ''}";
            files = "^(flake\\.nix|tests/fixtures/actionlint-shellcheck-smoke\\.yml|scripts/check-actionlint-shellcheck-active\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          # Guard: fail if any GitHub Actions run: block invokes
          # python/python3/pip while pyflakes is not wired into the
          # actionlint hook. No python run: exists today, so this is
          # a passive gate; the day one lands it fails with a pointer
          # to docs/actionlint-embedded-linters.md.
          check-run-block-pyflakes-required = {
            enable = true;
            name = "check-run-block-pyflakes-required";
            description = "Fail if a workflow run: invokes python without pyflakes wired.";
            entry = "${pkgs-unstable.writeShellScript "check-run-block-pyflakes-required-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-run-block-pyflakes-required.sh
            ''}";
            files = "^(\\.github/(workflows|actions)/.*\\.ya?ml|scripts/check-run-block-pyflakes-required\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
          # Asserts every #anchor fragment in markdown links across
          # README.md and docs/**/*.md matches a heading slug in the
          # target file (ASCII GFM/mkdocs rule).
          check-doc-anchors = {
            enable = true;
            name = "check-doc-anchors";
            description = "Every markdown #anchor link resolves to a heading slug in its target file.";
            entry = "${pkgs-unstable.writeShellScript "check-doc-anchors-hook" ''
              set -Eeuo pipefail
              IFS=$'\n\t'
              if [[ -n "''${NIX_BUILD_TOP:-}" ]]; then exit 0; fi
              exec ${pkgs-unstable.bash}/bin/bash scripts/check-doc-anchors.sh
            ''}";
            files = "^(README\\.md|docs/.*\\.md|scripts/check-doc-anchors\\.sh)$";
            pass_filenames = false;
            language = "system";
          };
        };

        # Wrap the bundled pre-commit binary to scrub PYTHONPATH before
        # exec. pre-commit's Python launcher uses `site.addsitedir`, which
        # APPENDS its bundled site-packages to sys.path — so any older
        # `pre_commit` module reachable via an externally-inherited
        # PYTHONPATH (a stale direnv profile, a parent shell that left
        # `python3Packages.pre-commit` on the path, etc.) wins over the
        # bundled one. When the inherited version pre-dates pre-commit
        # 4.4.0 it rejects `language: unsupported` (the post-4.4 default
        # emitted by git-hooks.nix) and every `git commit` fails before
        # any hook runs.
        #
        # Override via `overrideAttrs` rather than a separate wrapper
        # derivation so the upstream hook-tmpl resource (which has
        # `$out/bin/pre-commit` substituted at build time and ends up
        # baked into every `.git/hooks/pre-commit`) keeps pointing at the
        # binary committers actually run. A separate writeShellScriptBin
        # wrapper would not be reached by `pre-commit install` — only
        # `nix develop`-time invocations would see it.
        # actionlint discovers embedded shellcheck via $PATH. Hook
        # invocations from a shell that has not entered the devShell
        # (fresh checkout without direnv, CI step that forgot
        # `nix develop`) silently degrade: actionlint exits 0 with
        # shellcheck coverage disabled. Pinning the binary path here
        # makes discovery deterministic at flake evaluation. See
        # docs/actionlint-embedded-linters.md.
        actionlintWrapped = pkgs-unstable.writeShellScriptBin "actionlint" ''
          exec ${pkgs-unstable.actionlint}/bin/actionlint \
            -shellcheck=${pkgs-unstable.shellcheck}/bin/shellcheck \
            "$@"
        '';

        preCommitWrapped = pkgs-unstable.pre-commit.overrideAttrs (old: {
          postFixup = (old.postFixup or "") + ''
            mv "$out/bin/pre-commit" "$out/bin/.pre-commit-real"
            cat > "$out/bin/pre-commit" <<EOF
            #!${pkgs-unstable.bash}/bin/bash
            unset PYTHONPATH
            exec "$out/bin/.pre-commit-real" "\$@"
            EOF
            chmod +x "$out/bin/pre-commit"
          '';
        });

        preCommitCheck = pre-commit-hooks.lib.${system}.run {
          src = ./.;
          hooks = preCommitHooks;
          package = preCommitWrapped;
        };
      in
      {
        packages = {
          inherit linpeas;
          default = linpeas;
          # Exposed so release-on-bump.yml and verify-latest-release.yml
          # can call cosign via `nix shell .#cosign --command cosign ...`,
          # which resolves through this repo's flake.lock-pinned
          # nixpkgs rather than the runner registry's mutable
          # `nixpkgs` reference. See
          # docs/security/workflow-hardening.md (nix-run-pinned).
          inherit (pkgs-unstable) cosign git-cliff;
          # Exposed so actionlint-drift-check.yml can invoke the
          # shellcheck-pinned wrapper (`actionlintWrapped`, defined
          # above) via `nix run .#actionlint-wrapped -- ...`. Using
          # the flake output bypasses devShell PATH ordering — the
          # bare `actionlint` derivation otherwise shadows the
          # wrapper because `preCommitCheck.enabledPackages` lands
          # ahead of `buildInputs` on PATH. Same wrapper the
          # pre-commit hook (flake.nix:209) invokes.
          actionlint-wrapped = actionlintWrapped;
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          inherit linpeas-image site;
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
          # Wire the derivation builds into `nix flake check` so a
          # contributor running only the local check still exercises the
          # build path (fetchurl hash, patchShebangs, install rules).
          # `linpeas-image` is intentionally excluded — slow and
          # network-heavy; CI's `image-smoke` job covers it.
          linpeas-build = linpeas;
        };

        devShells.default = pkgs-unstable.mkShell {
          inherit (preCommitCheck) shellHook;

          buildInputs =
            preCommitCheck.enabledPackages
            ++ (with pkgs-unstable; [
              nix
              jq
              yq-go
              gh
              just
              curl
              git
              shellcheck
              shfmt
              nixfmt
              deadnix
              statix
              actionlint
              commitlint
              ratchet
              scorecard
              zizmor
              yamllint
              prettier
              treefmtEval.config.build.wrapper
              python3Packages.mkdocs-material
              python3Packages.mkdocs-macros
              lychee
              check-jsonschema
              renovate
            ]);
        };

        # Non-standard output (expect a harmless "unknown flake output" warning from
        # nix flake check): name -> description manifest of enabled pre-commit hooks,
        # consumed by scripts/refresh-precommit-table.sh via `nix eval --json`.
        # NOTE: hook descriptions must not contain '|' (they render into a markdown table cell).
        devTooling.preCommitHooks = pkgs.lib.mapAttrs (_: v: v.description) (
          pkgs.lib.filterAttrs (_: v: (v.enable or false) && (v ? description)) preCommitHooks
        );

        # Non-standard output (expect a harmless "unknown flake output" warning from
        # nix flake check): enabled-formatter manifest extracted from the evaluated
        # treefmt module, consumed by scripts/refresh-treefmt-config.sh via
        # `nix eval --json`. Coalesces missing includes/excludes to [] so the
        # consumer can iterate uniformly without null-guards.
        devTooling.treefmtConfig =
          let
            cfg = treefmtEval.config;
            enabled = pkgs.lib.filterAttrs (_: v: (v.enable or false)) cfg.programs;
            formatters = pkgs.lib.mapAttrsToList (name: v: {
              inherit name;
              includes = v.includes or [ ];
              excludes = v.excludes or [ ];
            }) enabled;
          in
          {
            inherit formatters;
            globalExcludes = cfg.settings.global.excludes or [ ];
          };
      }
    )
    // {
      overlays.default = _final: prev: {
        inherit (self.packages.${prev.stdenv.hostPlatform.system}) linpeas;
      };
    };
}
