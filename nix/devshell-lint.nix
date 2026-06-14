{
  perSystem =
    { pkgs-unstable, ... }:
    {
      # Minimal shell for the batched workflow-security / script-hygiene
      # invariant-lint jobs. Deliberately references neither `config.pre-commit`
      # nor the author tooling (renovate, mkdocs, scorecard, zizmor, lychee), so
      # entering it in CI pays neither the git-hooks module eval nor that large
      # closure realize. Doc-invariant lints stay on devShells.default because
      # renovate-config-validator pulls the heavy renovate closure.
      devShells.lint = pkgs-unstable.mkShell {
        buildInputs = with pkgs-unstable; [
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
      };
    };
}
