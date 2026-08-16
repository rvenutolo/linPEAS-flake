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
        #
        # `diffoscopeMinimal` is exposed for the same pinning reason,
        # and it matters most where it is used: reproducibility-check.yml
        # reaches for it precisely when a build stops being reproducible,
        # so the diagnostic must not depend on whatever a mutable
        # reference serves that week. The minimal variant is the one
        # exposed because the full package's closure is an order of
        # magnitude larger — more than a runner already holding two build
        # artifacts can substitute — while the handlers it drops are for
        # formats that job never compares; its inputs are a gzipped
        # tarball and a container image tar, both of which the minimal
        # handler set reads. The attribute keeps the upstream name so the
        # generated docs/reference/flake-outputs.md says which variant is
        # published; the binary it provides is `diffoscope`.
        inherit (pkgs-unstable)
          cosign
          diffoscopeMinimal
          git-cliff
          nix
          ;
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
