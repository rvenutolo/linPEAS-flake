# Install with Nix

The flake exposes a `linpeas` package, a runnable `linpeas` app, and an overlay. Pin and content integrity are enforced at eval and build time — see [Security → Trust model](../security/trust-model.md).

## Run without installing

```bash
nix run github:rvenutolo/linPEAS-flake -- -a
```

Equivalent to executing `linpeas -a` against the currently-pinned upstream `linpeas.sh`.

## Persistent install

```bash
nix profile install github:rvenutolo/linPEAS-flake
```

Adds `linpeas` to your Nix profile. Upgrade with `nix profile upgrade linpeas`.

## As a flake input

```nix
{
  inputs.linpeas-flake.url = "github:rvenutolo/linPEAS-flake";

  outputs = { self, nixpkgs, linpeas-flake, ... }: {
    # ...
    # access via: linpeas-flake.packages.${system}.linpeas
  };
}
```

## As an overlay

```nix
{
  nixpkgs.overlays = [ inputs.linpeas-flake.overlays.default ];
  # ...
  # then pkgs.linpeas is available
}
```

## Pin / version

The currently pinned upstream tag is `{{ dashboard.pin.version }}`. See the [Dashboard](../dashboard.md) for full pin metadata.
