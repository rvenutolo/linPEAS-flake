{
  perSystem =
    {
      pkgs-unstable,
      self',
      linpeas,
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
        #
        # `nix` is exposed for the same reason plus one more:
        # `nix flake show`'s text rendering differs between
        # implementations, so scripts/refresh-flake-show.sh pins which
        # nix renders the block. Without it the generated output
        # depends on whichever nix the operator has installed.
        inherit (pkgs-unstable) cosign git-cliff nix;
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
