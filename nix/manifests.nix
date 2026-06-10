{
  lib,
  config,
  withSystem,
  flake-parts-lib,
  ...
}:
{
  # Declare the non-standard `devTooling` perSystem output so flake-parts'
  # module system accepts it. It is consumed by repo refresh scripts via
  # `nix eval --json`, not by any standard flake consumer, so the type is
  # left fully freeform.
  options.perSystem = flake-parts-lib.mkPerSystemOption {
    options.devTooling = lib.mkOption {
      type = lib.types.unspecified;
      default = { };
    };
  };

  # flake-parts does not surface custom `perSystem` outputs at the top level.
  # The repo refresh scripts read `devTooling.<system>.preCommitHooks` and
  # `devTooling.<system>.treefmtConfig` via `nix eval --json`, so transpose
  # each system's perSystem `devTooling` value up to a top-level output.
  config.flake.devTooling = lib.genAttrs config.systems (
    system: withSystem system ({ config, ... }: config.devTooling)
  );
}
