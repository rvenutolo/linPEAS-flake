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
        # Later inputs propagate their own `python3` (yamllint and
        # mkdocs-material among them); listed first, the interpreter that
        # runs the check is the one built with its libraries rather than
        # whichever propagated `python3` sorts ahead. Its site-packages also
        # reach `PYTHONPATH` through the propagated interpreter's setup hook,
        # but only for an interpreter of the same minor version.
        # `checks.devshell-renderer-python` fails `nix flake check` if it
        # stops being first.
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

      # Fails its build, so `nix flake check` goes red while `nix flake
      # show` still evaluates, when `rendererPython` is not the first
      # `buildInputs` entry of `devShells.default`.
      checks.devshell-renderer-python =
        pkgs-unstable.runCommandLocal "check-devshell-renderer-python" { }
          (
            if builtins.head config.devShells.default.buildInputs == rendererPython then
              "touch $out"
            else
              ''
                echo "devShells.default: rendererPython must be the first buildInputs entry, or its python3 does not lead PATH (see nix/devshell.nix)" >&2
                exit 1
              ''
          );
    };
}
