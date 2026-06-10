{
  perSystem =
    {
      pkgs-unstable,
      self',
      linpeas,
      actionlintWrapped,
      ...
    }:
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
        # wrapper because `config.pre-commit.settings.enabledPackages`
        # lands ahead of `buildInputs` on PATH. Same wrapper the
        # `actionlint` pre-commit hook invokes.
        actionlint-wrapped = actionlintWrapped;
      };

      apps = {
        linpeas = {
          type = "app";
          program = "${linpeas}/bin/linpeas";
          meta = {
            description = "Linux Privilege Escalation Awesome Script (LinPEAS) from peass-ng";
          };
        };
        default = self'.apps.linpeas;
      };
    };
}
