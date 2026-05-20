# Install the portable bundle

For systems without Nix or Docker, each release attaches `linpeas-bundle.sh` — the raw upstream `linpeas.sh` with a portable `#!/usr/bin/env bash` shebang. A single, architecture-agnostic asset.

## Download and run

```bash
curl --location \
  https://github.com/rvenutolo/linPEAS-flake/releases/latest/download/linpeas-bundle.sh \
  --output linpeas
chmod +x linpeas
./linpeas -a
```

## Verify build provenance

```bash
gh attestation verify linpeas-bundle.sh --repo rvenutolo/linPEAS-flake
```

Confirms the bundle was produced by `release-on-bump.yml` in this repo.

## What the bundle actually is

`linpeas-bundle.sh` is byte-for-byte the upstream `linpeas.sh` (verified by SRI hash at build time), with line 1 rewritten from `#!/bin/sh` to `#!/usr/bin/env bash` so it runs portably on systems where `/bin/sh` is `dash` or `ash`. No other modifications. See `flake.nix` for the derivation source.

## Shebang guard

Build derivation checks upstream `linpeas.sh` has a shebang on line 1
before `sed` rewrite. `bundle-smoke` CI job asserts the **rewritten**
line 1 is exactly `#!/usr/bin/env bash`. Locks the arch-agnostic asset
contract.
