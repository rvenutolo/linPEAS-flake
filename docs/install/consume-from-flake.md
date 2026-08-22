# Consume linPEAS-flake as a flake input

This page covers importing this flake as an input to another flake.
For one-shot use see `nix run` and the Docker image in the project README.

## Plain flake consumer

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.linpeas-flake = {
    url = "github:rvenutolo/linPEAS-flake/<TAG>";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, linpeas-flake, ... }: {
    packages.x86_64-linux.linpeas =
      linpeas-flake.packages.x86_64-linux.default;
  };
}
```

Replace `<TAG>` with the latest release tag from
[releases](https://github.com/rvenutolo/linPEAS-flake/releases).

Both `packages.<system>.default` and `packages.<system>.linpeas` are exposed; they alias the same derivation.

## flake-parts consumer

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    linpeas-flake = {
      url = "github:rvenutolo/linPEAS-flake/<TAG>";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];
      perSystem = { inputs', ... }: {
        packages.linpeas = inputs'.linpeas-flake.packages.default;
      };
    };
}
```

## Pinning recommendation

Pin to a release tag (shaped `YYYYMMDD-<sha>`), not `main`. Both are
locked to a rev, but `nix flake update linpeas-flake` on a `main` input
advances to whatever `main` now points at; a tag pin only moves when you
change the tag.

Update the pin with:

```sh
nix flake update linpeas-flake
```

## No binary cache

This flake does not publish a substituter. The first import fetches
the upstream `linpeas.sh` asset directly from the pinned release URL
and installs it — no compilation. Subsequent evaluations hit your
local Nix store.
