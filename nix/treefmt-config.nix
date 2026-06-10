{
  perSystem =
    {
      pkgs,
      pkgs-unstable,
      config,
      ...
    }:
    {
      # treefmt configuration consumed by inputs.treefmt-nix.flakeModule.
      # Pinned to pkgs-unstable so formatter package closures match the rest
      # of the dev tooling. flakeCheck is disabled because the formatting
      # check is wired explicitly below as `checks.formatting` (preserving
      # that output name); the module still supplies `formatter.<system>`.
      treefmt = {
        imports = [ ../treefmt.nix ];
        pkgs = pkgs-unstable;
        flakeCheck = false;
      };

      # Non-standard output (expect a harmless "unknown flake output" warning from
      # nix flake check): enabled-formatter manifest extracted from the evaluated
      # treefmt module, consumed by scripts/refresh-treefmt-config.sh via
      # `nix eval --json`. Coalesces missing includes/excludes to [] so the
      # consumer can iterate uniformly without null-guards.
      devTooling.treefmtConfig =
        let
          cfg = config.treefmt;
          enabled = pkgs.lib.filterAttrs (_: v: (v.enable or false)) cfg.programs;
          formatters = pkgs.lib.mapAttrsToList (name: v: {
            inherit name;
            includes = v.includes or [ ];
            excludes = v.excludes or [ ];
          }) enabled;
        in
        {
          inherit formatters;
          globalExcludes = cfg.settings.global.excludes or [ ];
        };
    };
}
