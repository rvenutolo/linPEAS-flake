# Install with Docker

Each release publishes an OCI image to both Docker Hub (`docker.io/rvenutolo/linpeas`) and GitHub Container Registry (`ghcr.io/rvenutolo/linpeas`) with the upstream tag, plus `:latest` when that release is the newest.

## What this image is for

linpeas enumerates Linux privilege-escalation vectors against whatever filesystem, process table, and namespaces it sees. A vanilla `docker run` only exposes the container's own namespaces, so the report describes the **container**, not the host. That is intentional and useful for several workflows:

- **Container audit.** Join a running container's namespaces (`--pid=container:<target> --net=container:<target>`) or run it as a sidecar to audit that container's privesc surface — SUID binaries baked into a base image, secrets in `/etc`, sudoers misconfigurations, etc.
- **CI pipeline scanning.** Run linpeas inside an ephemeral build container in CI as a pre-deploy hardening gate.
- **Base-image hardening review.** Bring up a candidate base image, exec linpeas inside it, fail the review on findings above a threshold.
- **Forensics on a captured container filesystem.** Mount the suspect filesystem into the linpeas image and run with `-f <path>`.

For a **host** audit, linpeas needs to see the host. A live audit — running processes, network, users — needs linpeas on the host itself: run it there via Nix (`nix run github:rvenutolo/linPEAS-flake`); see [Install with Nix](nix.md) for a persistent install. From the image, the reachable form is a filesystem sweep of the host tree, bind-mounted read-only:

```bash
docker run --rm \
  -v /:/host:ro \
  rvenutolo/linpeas:latest -f /host
```

Upstream documents `-f` as scoping linpeas to a filesystem scan of the mounted tree — crons, timers, services, sockets, software, permissions, interesting files, API keys — with the live process, network, and user checks disabled (an upstream contract of the pinned release; nothing in this repo exercises it beyond `-h`). Host namespace flags (`--pid=host`, `--net=host`, `--ipc=host`) therefore change nothing under `-f` and are not needed. Omitting `-f` and the bind mount instead scans the container's own near-empty filesystem.

**Do not reach for `-d`.** Upstream documents it as the network host-discovery flag (`-d <IP/NETMASK>`), which exits before any privesc check runs.

This form exists for environments where Docker is the only available shipping vehicle.

## Run (default invocation, smoke test)

The default invocation below scans the **linpeas image itself** — a near-empty Nix-built container with no services, secrets, or users. It is useful as a smoke test confirming args reach the binary, not as a real audit. For real host or sidecar audits, see [What this image is for](#what-this-image-is-for) above and the host sweep it links.

```bash
# Docker Hub (default registry — no prefix needed)
docker run --rm rvenutolo/linpeas:latest -a

# Or pull explicitly from GitHub Container Registry
docker run --rm ghcr.io/rvenutolo/linpeas:latest -a
```

The image's `Entrypoint` is set to the linpeas binary, so any arguments after the image reference are passed straight to linpeas. Both registries serve the **same** image bytes — every release pushes the same loaded image to both, so the content digests match, and each registry's per-arch digests carry their own SLSA attestations.

## Pin to a specific tag

```bash
docker run --rm rvenutolo/linpeas:{{ dashboard.release.latest_tag or "<tag>" }} -a
# or
docker run --rm ghcr.io/rvenutolo/linpeas:{{ dashboard.release.latest_tag or "<tag>" }} -a
```

Version tags exactly match upstream `peass-ng/PEASS-ng` tags. Each
registry additionally carries `:latest` (when that release is the newest)
and the per-arch `<tag>-amd64` / `<tag>-arm64` tags naming the images
the multi-arch manifest indexes (the manifest itself is built from their
digests — see [Manifest digest-pinning](#manifest-digest-pinning)).

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

SLSA attestations cover the per-arch images, not the multi-arch index a
tag resolves to — see
[Verify build provenance](#verify-build-provenance) below for the
digest-resolution recipe and
[Security → Multi-arch attestations](../security/verification.md#multi-arch-attestations) for
the trust contract.

## Verify build provenance

Attestations exist only for the per-arch images. A bare tag (and the
`RepoDigests` value a tag pull records) resolves to the multi-arch
manifest index, which carries no attestation — verifying it fails with
a not-found error. Resolve your platform's arch-image digest from the
index first, then verify that digest (substitute `arm64` as needed):

```bash
# Docker Hub
DIGEST=$(docker buildx imagetools inspect docker.io/rvenutolo/linpeas:{{ dashboard.release.latest_tag or "<tag>" }} --raw |
  jq --raw-output '.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64").digest')
gh attestation verify "oci://docker.io/rvenutolo/linpeas@${DIGEST}" --repo rvenutolo/linPEAS-flake

# GitHub Container Registry
DIGEST=$(docker buildx imagetools inspect ghcr.io/rvenutolo/linpeas:{{ dashboard.release.latest_tag or "<tag>" }} --raw |
  jq --raw-output '.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64").digest')
gh attestation verify "oci://ghcr.io/rvenutolo/linpeas@${DIGEST}" --repo rvenutolo/linPEAS-flake
```

A successful verification proves the image was built by the
`release-on-bump.yml` workflow in this repo. It does **not** prove content
equivalence with upstream `linpeas.sh` — see
[Security → Verification](../security/verification.md).

## Manifest digest-pinning

Every `docker buildx imagetools create`, `docker manifest create`, and
`docker manifest annotate` invocation in this repo MUST name its source
images by immutable digest — an `@sha256:` literal or an `@${…DIGEST}`
expansion — never a mutable tag. The rule is repo-wide: workflows,
composite actions, scripts, and shell-fenced markdown are all scanned.
Target list names are exempt, because they are tags by necessity.

The rule's live instance is `release-on-bump.yml`'s `manifest` job, which
takes its source digests from `needs.image-*.outputs.{ghcr,hub}_digest`
rather than the `${VERSION}-amd64` / `${VERSION}-arm64` arch tags. Arch
tags can be rewritten between per-arch push and manifest create; digests
cannot.
