{
  lib,
  config,
  withSystem,
  ...
}:
{
  # flake-parts does not surface custom `perSystem` outputs at the top level.
  # The repo refresh scripts read `devTooling.<system>.preCommitHooks` and
  # `devTooling.<system>.treefmtConfig` via `nix eval --json`, so transpose
  # each system's perSystem `devTooling` value up to a top-level output.
  flake.devTooling = lib.genAttrs config.systems (
    system: withSystem system ({ config, ... }: config.devTooling)
  );
}
