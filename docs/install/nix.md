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

Installs `packages.<system>.default`. Nix names the resulting profile element after the flake (`linPEAS-flake`), not the package, so upgrade with `nix profile upgrade --all`, which is robust to the element name.

## As a flake input

```nix
{
  inputs.linpeas-flake.url = "github:rvenutolo/linPEAS-flake";

  outputs = { self, nixpkgs, linpeas-flake, ... }: {
    # ...
    # access via: linpeas-flake.packages.${system}.default
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

The flake declares packages for both Linux systems via flake-parts' `perSystem` (the `systems` list in `flake.nix`). CI coverage varies:

| System          | Flake builds | CI tested                |
| --------------- | ------------ | ------------------------ |
| `x86_64-linux`  | yes          | yes (`ubuntu-latest`)    |
| `aarch64-linux` | yes          | yes (`ubuntu-24.04-arm`) |

The OCI image (`linpeas-image`) is Linux-only by design — containers run a Linux kernel regardless of host OS.

`flake.lib.systems` is the single source of truth for the declared systems list above. CI's `flake-check` job runs `scripts/check-flake-systems-eval.sh`, which reads `flake.lib.systems` and force-evaluates each declared system's packages down to every package's derivation — not just the attribute names — failing with the system named if one breaks. `nix flake check` alone does not force per-system module thunks (e.g. a second nixpkgs input imported per `perSystem`), so a platform that silently stopped evaluating would otherwise pass CI undetected.

## Pin / version

The currently pinned upstream tag is `{{ dashboard.pin.version }}`. See the [Dashboard](../dashboard.md) for full pin metadata.
