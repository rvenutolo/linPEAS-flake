# Install with Docker

Each release publishes an OCI image to GitHub Container Registry with the upstream tag and `:latest`.

## Run

```bash
docker run --rm ghcr.io/rvenutolo/linpeas:latest -a
```

The image's `Entrypoint` is set to the linpeas binary, so any arguments after the image reference are passed straight to linpeas.

## Pin to a specific tag

```bash
docker run --rm ghcr.io/rvenutolo/linpeas:{{ dashboard.release.latest_tag or "20260510-cd4bd619" }} -a
```

Tags exactly match upstream `peass-ng/PEASS-ng` tags.

## Image contents

The image is minimal: `bashInteractive`, `coreutils`, and the `linpeas` binary. Some linpeas checks invoke external tools (`grep`, `sed`, `awk`) that are deliberately omitted from the image — see [Architecture → CI](../architecture/ci.md) for the rationale.

## Verify build provenance

```bash
gh attestation verify oci://ghcr.io/rvenutolo/linpeas:{{ dashboard.release.latest_tag or "<tag>" }} \
  --repo rvenutolo/linPEAS-flake
```

This proves the image was built by the `release-on-bump.yml` workflow in this repo. It does **not** prove content equivalence with upstream `linpeas.sh` — see [Security → Verification](../security/verification.md).
