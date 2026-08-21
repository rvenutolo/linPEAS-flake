{
  description = "Nix flake wrapping peass-ng/PEASS-ng linpeas.sh for `nix run`";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    pre-commit-hooks = {
      url = "github:cachix/git-hooks.nix/43b3c1ab9d40fb1dbb008f451988a91e375825e9";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    let
      # Single source of truth for the flake's declared systems. Referenced
      # both as flake-parts' `systems` (drives perSystem) and as
      # `flake.lib.systems` (drives scripts/check-flake-systems-eval.sh,
      # which force-evaluates every package derivation of each declared
      # system so a broken platform fails CI by name instead of silently
      # passing `nix flake check`).
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      inherit systems;
      imports = [
        inputs.treefmt-nix.flakeModule
        inputs.pre-commit-hooks.flakeModule
        ./nix/pin.nix
        ./nix/wrappers.nix
        ./nix/packages.nix
        ./nix/image.nix
        ./nix/checks.nix
        ./nix/treefmt-config.nix
        ./nix/devshell.nix
        ./nix/devshell-lint.nix
        ./nix/hooks/default.nix
        ./nix/manifests.nix
      ];
      # Inject the second nixpkgs ONCE so every perSystem module receives
      # `pkgs-unstable` as an arg (no per-module re-import). `pkgs` (stable)
      # is flake-parts' default from inputs.nixpkgs.
      perSystem =
        { system, ... }:
        {
          _module.args.pkgs-unstable = import inputs.nixpkgs-unstable { inherit system; };
        };
      flake = {
        lib.systems = systems;
        overlays.default = _final: prev: {
          inherit (inputs.self.packages.${prev.stdenv.hostPlatform.system}) linpeas;
        };
      };
    };
}
