{
  perSystem =
    {
      pkgs-unstable,
      config,
      ...
    }:
    {
      devShells.default = pkgs-unstable.mkShell {
        inherit (config.pre-commit) shellHook;

        buildInputs =
          config.pre-commit.settings.enabledPackages
          ++ (with pkgs-unstable; [
            # `nix` intentionally omitted: host runs Determinate Nix, which
            # provides `nix` on PATH. Pinning upstream nix here shadowed it
            # and warned on Determinate-only settings (eval-cores, lazy-trees)
            # in /etc/nix/nix.conf. `nix shell .#cosign` still works via host.
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
            config.treefmt.build.wrapper
            python3Packages.mkdocs-material
            python3Packages.mkdocs-macros
            lychee
            check-jsonschema
            renovate
          ]);
      };
    };
}
