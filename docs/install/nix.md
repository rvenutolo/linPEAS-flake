# Install with Nix

The flake exposes a `linpeas` package, a runnable `linpeas` app, and an overlay. The package runs linpeas under `dash`. Pin and content integrity are enforced at eval and build time — see [Security → Trust model](../security/trust-model.md).

## Run without installing

```bash
nix run github:rvenutolo/linPEAS-flake -- -a
```

Equivalent to executing `linpeas -a` against the currently-pinned upstream `linpeas.sh`.

`-a` turns on every check, including upstream's `su` password brute-force against other local accounts. On a shared or monitored host that can lock accounts or trip alerting; omit `-a` for the default check set, or add `-s` for a faster, quieter run.

To run one specific linpeas release rather than whatever `main` pins today, put its release tag in the flake reference:

```bash
nix run github:rvenutolo/linPEAS-flake/<tag> -- -a
```

Release tags match the upstream `peass-ng/PEASS-ng` tags verbatim; the [releases page](https://github.com/rvenutolo/linPEAS-flake/releases) lists them.

## Hash-checked script for a host without Nix

The installed `bin/linpeas` runs only where Nix is: line 1 is rewritten to name a Nix-store `dash`, because upstream targets a POSIX `/bin/sh` and bash aborts its regex searches. For a target without Nix, build `linpeas.src` instead — upstream's `linpeas.sh` byte for byte, fetched and checked against the pinned SRI hash — and run it with `sh`:

```bash
cp "$(nix build github:rvenutolo/linPEAS-flake#linpeas.src --no-link --print-out-paths)" linpeas.sh
scp linpeas.sh <host>:
ssh <host> sh linpeas.sh
```

Where the target's `sh` is bash (Fedora, Arch, and others), the same bash parsing bug applies: `-r` and `-f` abort partway through. Running it as `bash linpeas.sh` does not help — the run finishes, but it skips every API-key regex search after printing a `value too great for base` error. Run it with `dash linpeas.sh` there if `dash` is installed.

## Persistent install

```bash
nix profile add github:rvenutolo/linPEAS-flake
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

The flake declares packages for both Linux systems via flake-parts' `perSystem` (the `systems` list in `flake.nix`). Both are built and CI-tested by the same run steps; the arm64 jobs differ in runner label, in an arch tag on their job, step and build-artifact names (`-arm64` on the jobs and the artifact, `(aarch64)` on the steps), and — for the build and image-smoke jobs — in a larger timeout budget:

| System          | Flake builds | CI tested                |
| --------------- | ------------ | ------------------------ |
| `x86_64-linux`  | yes          | yes (`ubuntu-latest`)    |
| `aarch64-linux` | yes          | yes (`ubuntu-24.04-arm`) |

Both `linpeas-image` and `site` are gated on a Linux stdenv — the image because containers run a Linux kernel regardless of host OS — so adding a non-Linux system to the `systems` list in `flake.nix` would not publish them there.

The `systems` list in `flake.nix` is the single source of truth for the declared systems above; the flake re-exports it as `flake.lib.systems`, the attribute the checker reads. CI's `flake-check` job runs `scripts/check-flake-systems-eval.sh`, which reads `flake.lib.systems` and force-evaluates each declared system's packages down to every package's derivation — not just the attribute names — failing with the system named if one breaks. `nix flake check` alone does not force per-system module thunks (e.g. a second nixpkgs input imported per `perSystem`), so a platform that silently stopped evaluating would otherwise pass CI undetected.

## Pin / version

The currently pinned upstream tag is `{{ dashboard.pin.version }}`. See the [Dashboard](../dashboard.md) for full pin metadata.
