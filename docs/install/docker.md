# Install with Docker

Each release publishes an OCI image to both Docker Hub (`docker.io/rvenutolo/linpeas`) and GitHub Container Registry (`ghcr.io/rvenutolo/linpeas`) with the upstream tag and `:latest`. Both registries serve identical image bytes with matching SLSA attestations.

## What this image is for

linpeas enumerates Linux privilege-escalation vectors against whatever filesystem, process table, and namespaces it sees. A vanilla `docker run` only exposes the container's own namespaces, so the report describes the **container**, not the host. That is intentional and useful for several workflows:

- **Container audit.** Drop the image into a running container (`docker exec` or a sidecar) to audit that container's privesc surface — SUID binaries baked into a base image, secrets in `/etc`, sudoers misconfigurations, etc.
- **CI pipeline scanning.** Run linpeas inside an ephemeral build container in CI as a pre-deploy hardening gate.
- **Base-image hardening review.** Bring up a candidate base image, exec linpeas inside it, fail the review on findings above a threshold.
- **Forensics on a captured container filesystem.** Mount the suspect filesystem into the linpeas image and run with `-d <path>`.

For a **host** audit, linpeas needs to see the host. Either install via Nix (`nix run github:rvenutolo/linPEAS-flake`), grab the [portable bundle](bundle.md), or run the image with host namespaces explicitly:

```bash
docker run --rm \
  --pid=host --net=host --ipc=host --userns=host --privileged \
  -v /:/host:ro \
  rvenutolo/linpeas:latest -d /host
```

The bundle is usually simpler for host audits — this form exists for environments where Docker is the only available shipping vehicle.

## Run (container audit, default)

```bash
# Docker Hub (default registry — no prefix needed)
docker run --rm rvenutolo/linpeas:latest -a

# Or pull explicitly from GitHub Container Registry
docker run --rm ghcr.io/rvenutolo/linpeas:latest -a
```

The image's `Entrypoint` is set to the linpeas binary, so any arguments after the image reference are passed straight to linpeas. Both registries serve the **same** image bytes — every release pushes to both with identical content digests and matching SLSA attestations.

## Pin to a specific tag

```bash
docker run --rm rvenutolo/linpeas:{{ dashboard.release.latest_tag or "20260510-cd4bd619" }} -a
# or
docker run --rm ghcr.io/rvenutolo/linpeas:{{ dashboard.release.latest_tag or "20260510-cd4bd619" }} -a
```

Tags exactly match upstream `peass-ng/PEASS-ng` tags.

## Image contents

The image ships `bashInteractive`, `coreutils`, `gnugrep`, `gnused`, `gawk`, `findutils`, `procps`, and the `linpeas` binary. These cover the external tools linpeas invokes during its checks. Anything else linpeas tries to call (e.g. `lsof`, `netstat`, distro-specific helpers) will be missing — that is consistent with how linpeas behaves on a minimal host, and the script logs each missing tool rather than aborting.

## Architecture support

The image is published as a multi-arch manifest covering `linux/amd64`
(Intel/AMD, most servers) and `linux/arm64` (Apple Silicon under Docker
Desktop, AWS Graviton, Raspberry Pi 64-bit). `docker pull` automatically
selects the matching native image — no QEMU, no fallback.

To pull a specific arch explicitly:

```bash
docker pull --platform linux/arm64 rvenutolo/linpeas:latest
```

When verifying the SLSA attestation, point at the resolved arch-image
digest (not the manifest pointer):

{% raw %}

```bash
docker pull rvenutolo/linpeas:latest
DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' rvenutolo/linpeas:latest)
gh attestation verify "oci://${DIGEST}" --repo rvenutolo/linPEAS-flake
```

{% endraw %}

See [Security → Multi-arch attestations](../security/verification.md) for
the trust contract.

## Verify build provenance

```bash
# Docker Hub
gh attestation verify oci://docker.io/rvenutolo/linpeas:{{ dashboard.release.latest_tag or "<tag>" }} \
  --repo rvenutolo/linPEAS-flake

# GitHub Container Registry
gh attestation verify oci://ghcr.io/rvenutolo/linpeas:{{ dashboard.release.latest_tag or "<tag>" }} \
  --repo rvenutolo/linPEAS-flake
```

Proves image was built by `release-on-bump.yml` workflow in this repo. Does **not** prove content equivalence with upstream `linpeas.sh` — see [Security → Verification](../security/verification.md).
