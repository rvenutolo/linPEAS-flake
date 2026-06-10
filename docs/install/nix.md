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

## Platform support

The flake declares packages for all four systems via flake-parts' `perSystem` (the `systems` list in `flake.nix`). CI coverage varies:

| System           | Flake builds | CI tested                                  |
| ---------------- | ------------ | ------------------------------------------ |
| `x86_64-linux`   | yes          | yes (`ubuntu-latest`)                      |
| `aarch64-linux`  | yes          | yes (`ubuntu-24.04-arm`)                   |
| `aarch64-darwin` | yes          | yes (`macos-latest`)                       |
| `x86_64-darwin`  | yes          | **no** — no GitHub-hosted Intel-mac runner |

`x86_64-darwin` is declared because the upstream script is portable bash and is expected to work, but no automated test exercises it. If you run on an Intel Mac and hit a failure, please open an issue.

The OCI image (`linpeas-image`) is Linux-only by design — containers run a Linux kernel regardless of host OS.

## Pin / version

The currently pinned upstream tag is `{{ dashboard.pin.version }}`. See the [Dashboard](../dashboard.md) for full pin metadata.
