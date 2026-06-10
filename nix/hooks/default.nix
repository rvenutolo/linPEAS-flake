{ inputs, ... }:
{
  perSystem =
    {
      pkgs,
      pkgs-unstable,
      config,
      actionlintWrapped,
      preCommitWrapped,
      ...
    }:
    let
      hookArgs = {
        inherit pkgs-unstable inputs actionlintWrapped;
        treefmtWrapper = config.treefmt.build.wrapper;
      };
      hooks =
        (import ./nix.nix hookArgs)
        // (import ./linters.nix hookArgs)
        // (import ./workflow-security.nix hookArgs)
        // (import ./scripts.nix hookArgs)
        // (import ./freshness.nix hookArgs);
    in
    {
      pre-commit = {
        pkgs = pkgs-unstable;
        settings = {
          src = ../../.;
          inherit hooks;
          package = preCommitWrapped;
        };
      };
      # Non-standard output consumed by scripts/refresh-precommit-table.sh.
      # NOTE: hook descriptions must not contain '|' (markdown table cell).
      devTooling.preCommitHooks = pkgs.lib.mapAttrs (_: v: v.description) (
        pkgs.lib.filterAttrs (_: v: (v.enable or false) && (v ? description)) hooks
      );
    };
}
