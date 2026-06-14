{
  description = "Nix flake wrapping peass-ng/PEASS-ng linpeas.sh for `nix run`";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    pre-commit-hooks = {
      url = "github:cachix/git-hooks.nix/61ab0e80d9c7ab14c256b5b453d8b3fb0189ba0a";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
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
        overlays.default = _final: prev: {
          inherit (inputs.self.packages.${prev.stdenv.hostPlatform.system}) linpeas;
        };
      };
    };
}
