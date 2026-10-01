{
  perSystem =
    {
      pkgs-unstable,
      config,
      ...
    }:
    let
      rendererPython = import ./renderer-python.nix { inherit pkgs-unstable; };
    in
    {
      devShells.default = pkgs-unstable.mkShell {
        inherit (config.pre-commit) shellHook;

        # `rendererPython` comes first so its `python3` leads `PATH`. The
        # `lint-doc-invariants` group runs the scripts-reference round-trip
        # check here, and that check runs whatever `python3` leads `PATH`.
        # Later inputs propagate a plain `python3` (mkdocs-material among
        # them) that imports the check's libraries only through the
        # `PYTHONPATH` they propagate; listed after them, this entry is
        # shadowed and declares nothing. `checks.devshell-renderer-python`
        # fails the build if it stops being first.
        buildInputs = [
          rendererPython
        ]
        ++ config.pre-commit.settings.enabledPackages
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

      # Reordering `buildInputs` puts a propagated `python3` ahead of
      # `rendererPython`, and nothing else would notice until a nixpkgs
      # bump stops mkdocs-material propagating a library the check needs.
      checks.devshell-renderer-python =
        if builtins.head config.devShells.default.buildInputs == rendererPython then
          pkgs-unstable.runCommandLocal "check-devshell-renderer-python" { } "touch $out"
        else
          throw "devShells.default: rendererPython must be the first buildInputs entry, or its python3 does not lead PATH (see nix/devshell.nix)";
    };
}
