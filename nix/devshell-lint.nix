{
  perSystem =
    { pkgs-unstable, ... }:
    let
      # Single source of truth for the tools the batched `.#lint`-hosted
      # invariant-lint groups need. Consumed twice: by `devShells.lint`
      # (the shell CI actually enters) and by `checks.lint-shell-tools`
      # (which asserts the declared list still covers every tool
      # scripts/check-lint-shell-tools.sh expects). One list, so the shell
      # and the guard cannot disagree.
      lintTools = with pkgs-unstable; [
        bash
        coreutils
        gnugrep
        gnused
        gawk
        findutils
        yq-go
        jq
        gh
        git
        shellcheck
        shfmt
        actionlint
        check-jsonschema
      ];
    in
    {
      # Minimal shell for the batched workflow-security / script-hygiene
      # invariant-lint jobs. Deliberately references neither `config.pre-commit`
      # nor the author tooling (renovate, mkdocs, scorecard, zizmor, lychee), so
      # entering it in CI pays neither the git-hooks module eval nor that large
      # closure realize. Doc-invariant lints stay on devShells.default because
      # renovate-config-validator pulls the heavy renovate closure.
      devShells.lint = pkgs-unstable.mkShell {
        buildInputs = lintTools;
      };

      # Hermetic counterpart to the shell above: runs the tool guard with
      # `PATH` set to exactly `lintTools`, so a package dropped from the
      # list fails the build by name. Running the same script against an
      # ambient `PATH` cannot do this — every expected tool is also in
      # `devShells.default`, so the drop stays invisible until CI enters
      # `devShells.lint`. `PATH` is scoped to the single command rather
      # than exported, leaving stdenv's own phases their normal
      # environment.
      checks.lint-shell-tools = pkgs-unstable.runCommandLocal "check-lint-shell-tools" { } ''
        PATH="${pkgs-unstable.lib.makeBinPath lintTools}" \
          ${pkgs-unstable.bash}/bin/bash ${../scripts/check-lint-shell-tools.sh}
        touch "$out"
      '';
    };
}
