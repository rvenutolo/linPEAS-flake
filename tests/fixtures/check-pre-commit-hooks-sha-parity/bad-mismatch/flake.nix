{
  inputs = {
    pre-commit-hooks = {
      url = "github:cachix/git-hooks.nix/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = _: { };
}
