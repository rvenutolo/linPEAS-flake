# Trust model

This page expands the trust model briefly described in [`SECURITY.md`](https://github.com/rvenutolo/linPEAS-flake/blob/main/SECURITY.md). Read both.

## What this wrapper guarantees

1. **Hash-pinned upstream fetch.** `linpeas-pin.json` records an SRI hash for the upstream `linpeas.sh` asset. Nix refuses to build on hash mismatch — a swapped or corrupted upstream asset fails the build.
2. **Pin-shape validation at flake eval.** `flake.nix` asserts that `pin.version` matches `[0-9]{8}-[0-9a-f]{7,40}` and that `pin.url` starts with `https://github.com/peass-ng/PEASS-ng/releases/download/`. An attacker-controlled pin file cannot smuggle arbitrary URLs into the derivation.
3. **GitHub Releases API digest cross-check.** `scripts/bump-linpeas.sh` reads the upstream release-asset `.digest` field over the API and refuses to bump if it is missing, non-`sha256:`, or does not match the downloaded file. This is **not** silent on missing data — bump aborts.
4. **Asset URL prefix validation.** Same script refuses to record any asset URL outside the expected `peass-ng/PEASS-ng/releases/download/` prefix.
5. **Daily upstream parity check.** `verify-latest-release.yml` re-fetches the pinned `linpeas.sh` daily and re-checks the SRI hash. Detects upstream tag replacement (intentional or compromised).
6. **SLSA build provenance attestations.** Each release attaches attestations binding the pin file, the bundle, and the OCI image to the `release-on-bump.yml` workflow run. Verifiable with `gh attestation verify` — see [Verification](verification.md).

## What this wrapper does **not** guarantee

- **Content trust on upstream `linpeas.sh`.** Upstream PEASS-ng ships no GPG, cosign, or SLSA signatures. The SRI hash binds you to *some* upstream asset, but it cannot prove that upstream's release is benign. If upstream is compromised, this wrapper will faithfully ship the compromise.
- **Reproducibility of upstream.** The wrapper is reproducible. The wrapped script is whatever upstream chose to publish.
- **Site-level signing.** The Pages site you are reading is documentation, not a verifiable artifact. Do not treat dashboard text as a substitute for `gh attestation verify`.

## Auto-merge surface

Three automations may auto-merge PRs into `main` when CI passes:

1. **`update-linpeas.yml`** — daily 09:00 UTC pin bumps. Opens a PR authored by `github-actions[bot]`, gated by all required CI checks, auto-merged on green.
2. **`update-flake-lock.yml`** — weekly nixpkgs input bump. Same gating.
3. **Renovate** — Friday batch for GitHub Action SHA pins and the pinned Nix installer version in CI workflows. Same gating.

A compromise of the **`BUMP_PAT`** fine-grained PAT used by `update-linpeas.yml` would let an attacker open a PR with arbitrary changes. The PAT is scoped to `contents:write` + `pull-requests:write` on this repo only, but the auto-merge bot would still gate on CI — so any malicious change would have to also pass all required checks (build, smoke, attestation re-verify, SRI cross-check).

See `SECURITY.md` for the secret rotation policy.

## Currently pinned

| Field | Value |
|-------|-------|
| Pin version | `{{ dashboard.pin.version }}` |
| Pin URL | [{{ dashboard.pin.url }}]({{ dashboard.pin.url }}) |
| Upstream latest | `{{ dashboard.drift.upstream_latest }}` |
| Drift | {{ dashboard.drift.days }} days |
| Last parity check | {{ dashboard.parity.conclusion }} ({{ dashboard.parity.checked_at }}) |
