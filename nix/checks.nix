{ inputs, ... }:
{
  perSystem =
    {
      config,
      linpeas,
      ...
    }:
    {
      checks = {
        formatting = config.treefmt.build.check inputs.self;
        # `checks.pre-commit` is supplied by the flakeModule.
        # Wire the derivation builds into `nix flake check` so a
        # contributor running only the local check still exercises the
        # build path (fetchurl hash, patchShebangs, install rules).
        # `linpeas-image` is intentionally excluded — slow and
        # network-heavy; CI's `image-smoke` job covers it.
        linpeas-build = linpeas;
      };
    };
}
