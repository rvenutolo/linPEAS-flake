# Threat model

## Purpose

This page sketches the trust boundaries the project crosses and the
controls that defend each boundary. It is a posture overview for new
contributors and security reviewers — not a binding invariant. The
canonical wording for each control lives in the linked `docs/security/`
file; this page exists so a reader can locate the right control without
reconstructing the model from the invariant index.

## Trust boundaries

```mermaid
flowchart LR
    upstream[peass-ng/PEASS-ng release] --> bot[bump-linpeas.sh<br/>GitHub App token]
    bot --> ci[CI pipeline<br/>signed release]
    ci --> art[GitHub Releases<br/>GHCR + Docker Hub]
    art --> consumer[downstream flake/docker user]
```

## Per-boundary threats and mitigations

### upstream → bot

**Threats:** tampered upstream release asset, MITM during download,
upstream account compromise post-release.

**Mitigations:**

- SRI digest pin in `linpeas-pin.json`, written by
    `scripts/bump-linpeas.sh` only.
- Per-release `.digest` recorded alongside the version.
- URL-prefix lock to `https://github.com/peass-ng/PEASS-ng/releases/`.

See [`docs/security/verification.md`](verification.md).

### bot → ci

**Threats:** malicious workflow injection, untrusted action code
execution, secret exfiltration from third-party actions.

**Mitigations:**

- Every `uses:` is SHA-pinned (full 40-char commit SHA, not tag).
- `permissions:` allowlist per workflow vendor (no `*`).
- `harden-runner` is the first step in every job.
- PR-triggered workflows expose only `secrets.GITHUB_TOKEN`.

See [`docs/security/repo-config.md`](repo-config.md),
[`docs/security/allowed-actions.md`](allowed-actions.md),
and [`docs/security/trust-model.md`](trust-model.md).

### ci → art

**Threats:** artifact substitution, unauthorized release tag, commit
forgery on `main`.

**Mitigations:**

- Tag-protection ruleset (`release-tag-protection`) gates who can push
    release tags; drift-check lint asserts the ruleset is intact.
- Releases are web-flow signed; no PAT, no `git push` from the bot.
- `protect-main` ruleset enforces required checks and signed commits.

See [`docs/security/repo-config.md`](repo-config.md)
and [`docs/security/trust-model.md`](trust-model.md).

### art → consumer

**Threats:** stale or compromised container image, manifest tampering
between registry and pull, supply-chain vulnerability in a transitive
dependency.

**Mitigations:**

- Multi-arch manifests are created with `buildx imagetools create` using
    `@sha256:` digest references — no tag-only manifests.
- Trivy CVE scan and SBOM generation run on every release (non-blocking by design; failures surface as CI annotations).
- Docker Hub push credentials are split into `_RW` and `_DELETE` tokens,
    never an unsuffixed PAT.

See [`docs/security/verification.md`](verification.md)
and [`docs/install/docker.md`](../install/docker.md).

## Out of scope

- Runtime LinPEAS behavior on the target system (this project ships
    the binary; what it does is upstream's design).
- Upstream PEASS-ng compromise prior to release publication (we pin
    what they publish; their internal release pipeline is outside our
    trust boundary).
- The downstream consumer's Nix store, Docker daemon, or host integrity.
