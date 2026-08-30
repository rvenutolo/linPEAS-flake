---
hide:
  - navigation
---

# linPEAS-flake

[![CI](https://github.com/rvenutolo/linPEAS-flake/actions/workflows/ci.yml/badge.svg)](https://github.com/rvenutolo/linPEAS-flake/actions/workflows/ci.yml)
[![Pages](https://github.com/rvenutolo/linPEAS-flake/actions/workflows/pages.yml/badge.svg)](https://github.com/rvenutolo/linPEAS-flake/actions/workflows/pages.yml)
[![Latest release](https://img.shields.io/github/v/release/rvenutolo/linPEAS-flake)](https://github.com/rvenutolo/linPEAS-flake/releases)
[![License](https://img.shields.io/github/license/rvenutolo/linPEAS-flake)](https://github.com/rvenutolo/linPEAS-flake/blob/main/LICENSE)

Personal Nix-flake wrapper around [peass-ng/PEASS-ng](https://github.com/peass-ng/PEASS-ng) `linpeas.sh`. All credit for LinPEAS itself belongs to the PEASS-ng authors.

<div class="status-tiles" markdown>

<div class="status-tile" markdown>
**Pin**

`{{ dashboard.pin.version }}`

</div>

<div class="status-tile {{ 'ok' if dashboard.drift.days == 0 else 'fail' }}" markdown>
**Drift**

{{ dashboard.drift.days }} day{{ '' if dashboard.drift.days == 1 else 's' }}

</div>

<div class="status-tile" markdown>
**Latest release**

`{{ dashboard.release.latest_tag or "—" }}`

</div>

<div class="status-tile {{ 'ok' if dashboard.parity.conclusion == 'success' else 'fail' }}" markdown>
**Upstream parity**

{{ dashboard.parity.conclusion }}

</div>

</div>

## Install

=== "Nix"

    ```bash
    nix run github:rvenutolo/linPEAS-flake -- -a
    ```

    Persistent: `nix profile add github:rvenutolo/linPEAS-flake`. Full options on the [Nix install page](install/nix.md).

=== "Docker"

    ```bash
    docker run --rm -v /:/host:ro ghcr.io/rvenutolo/linpeas:latest -f /host
    ```

    That audits the host filesystem. Sidecar (container) audits, the image-only smoke test, and tag-pinned alternatives are on the [Docker install page](install/docker.md).

=== "Flake input"

    ```nix
    {
      inputs.linpeas-flake.url = "github:rvenutolo/linPEAS-flake";
    }
    # access via: inputs.linpeas-flake.packages.${system}.default
    ```

    Overlay form on the [Nix install page](install/nix.md).

## What this is

A thin Nix wrapper. Upstream releases `linpeas.sh`; this repo pins the asset by SRI hash, asserts pin shape at flake-eval, cross-checks the GitHub Releases API `.digest` field on each bump, and re-verifies upstream parity weekly. Three automation groups keep the flake current, and a fourth watches that the weekly dependency upkeep is still refreshing inputs — see [Architecture → Auto-update](architecture/auto-update.md).

## Trust model in 60 seconds

- Build provenance: every release artifact has a SLSA attestation. `gh attestation verify <artifact> --repo rvenutolo/linPEAS-flake` proves it was built here.
- Content trust on upstream: upstream PEASS-ng ships no signatures. SRI hash binds you to a specific upstream artifact, not to a particular author. If upstream is compromised, the wrapper faithfully ships the compromise.
- Site: documentation only, **not** a trust anchor.

Full breakdown: [Security → Trust model](security/trust-model.md) → [Verification walkthrough](security/verification.md).

## Live status

→ [Dashboard](dashboard.md)
