{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    pre-commit-hooks = {
      url = "github:cachix/git-hooks.nix/61ab0e80d9c7ab14c256b5b453d8b3fb0189ba0a";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = _: { };
}
