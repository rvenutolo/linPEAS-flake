# Verification walkthrough

Step-by-step procedure to verify a release of this wrapper. None of this trusts the Pages site you are reading.

<!-- mdformat-toc start --slug=github --maxlevel=3 --minlevel=2 -->

- [Tools needed](#tools-needed)
- [1. Verify the OCI image's build provenance](#1-verify-the-oci-images-build-provenance)
- [Multi-arch attestations](#multi-arch-attestations)
- [2. Verify the weekly parity check is current](#2-verify-the-weekly-parity-check-is-current)
- [Bump-script integrity guards](#bump-script-integrity-guards)
- [verify-latest-release upstream parity](#verify-latest-release-upstream-parity)
- [verify-latest-release failure attribution](#verify-latest-release-failure-attribution)
- [Gitleaks secret scanning](#gitleaks-secret-scanning)
- [Dependency review](#dependency-review)
- [OCI image CVE scan (Trivy)](#oci-image-cve-scan-trivy)
- [OCI image CVE scan (Grype)](#oci-image-cve-scan-grype)
- [SBOM attestation](#sbom-attestation)
- [Cosign keyless signatures](#cosign-keyless-signatures)
  - [Identity pinning](#identity-pinning)
  - [User-facing verification commands](#user-facing-verification-commands)
- [Release-asset provenance sidecars](#release-asset-provenance-sidecars)
- [gh-attestation-repo invariant](#gh-attestation-repo-invariant)
- [cosign-identity-pinned invariant](#cosign-identity-pinned-invariant)

<!-- mdformat-toc end -->

## Tools needed<a name="tools-needed"></a>

- `gh` (GitHub CLI) ≥ 2.40 — `gh attestation verify` subcommand.
- `curl` — for direct asset download.
- `sha256sum` and/or `openssl` — for hash recomputation.
- `nix` (optional) — for SRI hash recompute.

## 1. Verify the OCI image's build provenance<a name="1-verify-the-oci-images-build-provenance"></a>

```bash
gh attestation verify \
  oci://ghcr.io/rvenutolo/linpeas:{{ dashboard.release.latest_tag or "<tag>" }} \
  --repo rvenutolo/linPEAS-flake
```

Same trust model: proves the image was built by this repo's release workflow.

## Multi-arch attestations<a name="multi-arch-attestations"></a>

The published OCI image is a multi-arch manifest covering `linux/amd64`
and `linux/arm64`. **SLSA attestations are per-arch**, not per-manifest.
This means:

- `gh attestation verify oci://docker.io/rvenutolo/linpeas:<tag> --repo rvenutolo/linPEAS-flake` may
    not resolve cleanly against the manifest index alone — point the verify
    at the arch-specific image (or pull on the target arch and use the
    resolved `RepoDigests` value).
- Each arch image was independently built from the same commit of this
    repo, so the attestations cover the same source provenance.
- The manifest index itself is **not** attested. An attacker with push
    to either registry could repoint the manifest at unattested images;
    the verify step in `release-on-bump.yml` would catch this at release
    time, but consumers who only verify the manifest pointer (not the
    arch image) would miss it. Always verify against the resolved
    arch-image digest.

## 2. Verify the weekly parity check is current<a name="2-verify-the-weekly-parity-check-is-current"></a>

```bash
gh run list \
  --workflow verify-latest-release.yml \
  --repo rvenutolo/linPEAS-flake \
  --limit 1 \
  --json conclusion,updatedAt,url
```

Look for `"conclusion": "success"` within the last 7 days. Current state on the Pages site: **{{ dashboard.parity.conclusion }}** at {{ dashboard.parity.checked_at }}.

## Bump-script integrity guards<a name="bump-script-integrity-guards"></a>

`scripts/bump-linpeas.sh`:

- Asset URL must start with
    `https://github.com/peass-ng/PEASS-ng/releases/download/`. Hard fail.
- GitHub-API `.digest` field never silently skipped. Absent or
    non-`sha256:` prefix is a hard fail.
- Pin file written via `mktemp` + `mv` (atomic). Never `>`.
- Every `gh api` call must pass `--header "X-GitHub-Api-Version: 2022-11-28"`.
    Apply to any new security-sensitive GitHub-REST caller.

Guards 1–3 are lint-enforced by `scripts/check-bump-script-integrity.sh`
(regex-presence over `scripts/bump-linpeas.sh`); guard 4 by
`scripts/check-gh-api-version-header.sh`. Both run in the
`lint-script-hygiene` CI job and as pre-commit hooks.

## verify-latest-release upstream parity<a name="verify-latest-release-upstream-parity"></a>

The weekly verify cron re-fetches the pinned `linpeas.sh` URL, recomputes the SRI
hash via `openssl dgst -sha256 -binary | base64 --wrap=0`, compares against
`linpeas-pin.json`. Failure = security incident.

## verify-latest-release failure attribution<a name="verify-latest-release-failure-attribution"></a>

`verify-latest-release.yml`'s notify body distinguishes failure
reasons via per-step `id:` outcomes mapped to a `reason` token by
the `attribute failure reason` step. Reasons:

- `upstream-sri-drift` — **security incident.** Upstream
    `linpeas.sh` SHA-256 no longer matches the pinned SRI.
- `manifest-tag-drift` — `:latest` no longer resolves to the same
    manifest as `:VERSION` on ghcr.io or docker.io.
- `ghcr-attest-failed` / `hub-attest-failed` /
    `pin-attest-failed` — attestation
    verification failed for a specific artifact.
- `release-tag-fetch-failed` / `release-asset-download-failed` —
    transient GitHub API / asset visibility lag.
- `pin-blob-sig-failed` — cosign verify-blob failed for
    `linpeas-pin.json` on the latest release. Indicates the
    `.sigstore` sidecar is missing or no longer verifies against
    the pinned workflow identity. Triage: re-trigger
    `release-on-bump.yml` via `workflow_dispatch` with
    `force-republish: true` if the sidecar is missing.
- `sbom-amd64-blob-sig-failed` — same failure for the amd64
    CycloneDX SBOM asset. Responsibility lives in the
    `image-amd64` job of `release-on-bump.yml`.
- `sbom-arm64-blob-sig-failed` — same failure for the arm64
    CycloneDX SBOM asset. Responsibility lives in the
    `image-arm64` job of `release-on-bump.yml`.
- `images-cosign-failed` — `cosign verify` of the published per-arch and
    index images failed against the pinned workflow identity and OIDC issuer.
    Treat as a signing-chain incident, adjacent in severity to the
    `*-attest-failed` reasons.
- `unknown` — attribution step couldn't match a known failed step
    (bug in the attribute logic itself).

Only `upstream-sri-drift` (and to a lesser extent `manifest-tag-drift`)
warrant the "treat as security incident" framing. Folding all reasons
into a single failure body trains the maintainer to skim-read auto-filed
issues — exactly the wrong reflex when the failure is a real SRI drift.

This pattern is the project default for every cron-notify caller: each
must attribute distinct failure reasons to distinct issue-body wording.
Alert fatigue is a security risk.

## Gitleaks secret scanning<a name="gitleaks-secret-scanning"></a>

`gitleaks.yml` scans the full git history (`fetch-depth: 0`) on push to
main, every PR, and a weekly Friday cron. Required check named
`gitleaks` in the `protect-main` ruleset.

- Uses only `secrets.GITHUB_TOKEN` — PR-triggered workflow secret
    allowlist invariant holds.
- New leaked-secret finding = security incident. Triage:
    rotate → purge with `git filter-repo` → force-push (admin bypass).
- Vendor `gitleaks/*` is in the `allowed_actions` allowlist; do not
    remove without replacing the workflow.

## Dependency review<a name="dependency-review"></a>

`dependency-review.yml` runs on every PR via
`actions/dependency-review-action`. Required check named
`dependency-review`. `fail-on-severity: moderate`,
`comment-summary-in-pr: on-failure`.

- Repo has no traditional package manifests today; the action mostly scans `.github/workflows/**` `uses:` against the GitHub Advisory DB + license policy. Belt-and-braces backup to SHA-pinning + Renovate + zizmor.
- If a future PR adds a real manifest (npm/cargo/pip/etc.), the action
    begins scanning it without any workflow change.

## OCI image CVE scan (Trivy)<a name="oci-image-cve-scan-trivy"></a>

`image-cve-scan.yml`'s `image-cve-scan-trivy` job (weekly cron +
dispatch) uploads SARIF (CRITICAL + HIGH) to code-scanning, then
post-processes the SARIF to count CRITICAL findings and **fails the
job** when count > 0. The job emits an `outputs.has-finding` boolean
(`'true'` iff the count step ran and returned a non-zero count) so
notify jobs can distinguish a real CRITICAL CVE from an
infrastructure failure that prevented the scan.

Two follow-on jobs (`needs: image-cve-scan-trivy`) gate on that
output and open / update deduped issues via
`notify-workflow-result`:

- `image-cve-scan-trivy-notify-finding` (label: `image-cve-critical-trivy`) — real
    CRITICAL CVE reported by Trivy. Remediation: bump `nixpkgs`.

- `image-cve-scan-trivy-notify-infra` (label: `image-cve-infra-trivy`) — job failed
    before Trivy produced a CRITICAL count (build, scan, or SARIF
    upload broke), or the job was cancelled (timeout). Remediation:
    inspect the failing step; if transient, close once the next
    scheduled run is green.

- NOT in required-checks (intentional — `update-flake-lock` must still
    land even if a CVE is present, with explicit maintainer awareness).

- Trivy's own `exit-code: "0"` + `ignore-unfixed: true` intentional;
    the CRITICAL-fail decision lives in the `fail on CRITICAL findings`
    step so the SARIF upload always runs.

- Prevention path: nixpkgs auto-bump via `update-flake-lock`. CRITICAL
    finding → bump nixpkgs, then rebuild the OCI image.

- CRITICAL threshold is hardcoded to CVSS `>= 9.0` per GitHub's current
    Code Scanning mapping. The `jq tonumber? // 0` guard drops non-numeric
    SARIF severities (e.g. textual `"high"` from some scanners) instead
    of erroring under `set -euo pipefail`. Revisit the threshold if
    GitHub revises the CVSS-to-bucket mapping.

## OCI image CVE scan (Grype)<a name="oci-image-cve-scan-grype"></a>

`image-cve-scan.yml`'s `image-cve-scan-grype` job (weekly cron +
dispatch) uploads SARIF (CRITICAL + HIGH) to the Security tab under
category `grype-image-cve`, using Grype as a second-opinion scanner
alongside Trivy. The job itself fails (and emits a notify issue) only
when one or more CRITICAL findings are reported. Advisory only — not
a required status check; prevention path is a nixpkgs bump via
`update-flake-lock`.

Two follow-on jobs (`needs: image-cve-scan-grype`) open or update a
deduped issue via the `notify-workflow-result` composite:

- `image-cve-scan-grype-notify-finding` (label: `image-cve-critical-grype`) — real
    CRITICAL CVE was identified by Grype.
- `image-cve-scan-grype-notify-infra` (label: `image-cve-infra-grype`) — job failed
    before producing a CRITICAL count (build / scan / SARIF upload),
    or the job was cancelled (timeout).

## SBOM attestation<a name="sbom-attestation"></a>

`release-on-bump.yml` generates CycloneDX-JSON SBOMs via `anchore/sbom-action`,
attests via `actions/attest-sbom`.

- Per-arch image SBOMs: attested + pushed to ghcr.io and docker.io with
    `push-to-registry: true`, **and** uploaded as release assets with
    `.sigstore` + `.intoto.jsonl` sidecars.
- `verify-latest-release.yml`'s `gh attestation verify` covers SBOMs
    automatically (verifies ALL attestations).

## Cosign keyless signatures<a name="cosign-keyless-signatures"></a>

In addition to `actions/attest-build-provenance` + `actions/attest-sbom`
(verifiable via `gh attestation verify`), `release-on-bump.yml` signs
every published image digest with Sigstore cosign in keyless mode.
Signatures are minted with an ephemeral Fulcio cert issued against the
workflow's OIDC token, then recorded in Rekor.

Signed artifacts per release:

- **Per-arch images**: `cosign sign <reg>/rvenutolo/linpeas@<digest>` on
    both `ghcr.io` and `docker.io`. The signature lands as a `.sig` tag
    next to each image in each registry.
- **Multi-arch index**: same `cosign sign` invocation against the OCI
    index digest of `:VERSION` (which equals the digest of `:latest`,
    since they reference identical bytes). One signature per registry
    covers both tags.

### Identity pinning<a name="identity-pinning"></a>

Verification must pin both:

- `--certificate-identity https://github.com/rvenutolo/linPEAS-flake/.github/workflows/release-on-bump.yml@refs/heads/main`
- `--certificate-oidc-issuer https://token.actions.githubusercontent.com`

A signature minted by any other workflow, branch ref, or OIDC issuer
fails verification. The release pipeline's `verify` job and the weekly
`verify-latest-release.yml` cron both enforce these exact values.

### User-facing verification commands<a name="user-facing-verification-commands"></a>

Image (any tag or digest works; both registries are signed):

```bash
cosign verify \
  --certificate-identity 'https://github.com/rvenutolo/linPEAS-flake/.github/workflows/release-on-bump.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  ghcr.io/rvenutolo/linpeas:latest
```

No `gh` CLI required. Pairs with the existing `gh attestation verify`
path — pick whichever toolchain fits the consumer's pipeline.

#### Release-asset blob signatures<a name="release-asset-blob-signatures"></a>

Each GitHub Release asset has a sibling `.sigstore` bundle:

- `linpeas-pin.json` + `linpeas-pin.json.sigstore`
- `linpeas-image-amd64.cdx.json` + `linpeas-image-amd64.cdx.json.sigstore`
- `linpeas-image-arm64.cdx.json` + `linpeas-image-arm64.cdx.json.sigstore`

Download both files for the asset you want to verify, then run
`cosign verify-blob` with the same identity pin used for image
signatures:

```bash
gh release download <tag> \
  --pattern linpeas-pin.json \
  --pattern linpeas-pin.json.sigstore

cosign verify-blob \
  --certificate-identity 'https://github.com/rvenutolo/linPEAS-flake/.github/workflows/release-on-bump.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  --bundle linpeas-pin.json.sigstore \
  linpeas-pin.json
```

Same shape for both SBOM sidecars — swap the asset names.

Why blob sigs in addition to the existing GitHub Attestations? The
attestations live in the GitHub Attestations API + Rekor and verify
via `gh attestation verify`. The `.sigstore` sidecars are file-system
sibling artifacts on the GitHub Release, which is what OpenSSF
Scorecard's `Signed-Releases` check scans for — and what consumers
without `gh` CLI can verify with just `cosign`.

## Release-asset provenance sidecars<a name="release-asset-provenance-sidecars"></a>

Every release asset is published alongside a sibling
`<asset>.intoto.jsonl` file containing a SLSA Build Provenance v1
attestation whose subject is the asset's content hash. The bundle is
captured from `actions/attest-build-provenance` at release time and
uploaded as a release asset.

The sidecar serves two consumers:

- **OSSF Scorecard `Signed-Releases`** — its
    `releasesHaveProvenance` probe matches release-asset suffix
    `.intoto.jsonl` only, and does not query the GitHub Attestations
    API. Without the sidecar, the per-release score caps at 8 (signed
    but no provenance).
- **Manual verification** — consumers can verify the bundle with
    `gh attestation verify <asset> --bundle <asset>.intoto.jsonl --repo rvenutolo/linPEAS-flake`
    against the same Fulcio + Rekor trust root used by the
    `.sigstore` signatures.

The contract is: for every `<asset>` in a release, both
`<asset>.sigstore` (cosign signature bundle) and
`<asset>.intoto.jsonl` (build provenance bundle) MUST be present.
A release missing either sidecar is a regression; the recovery
procedure lives in
[docs/runbooks/scorecard-signed-releases-backfill.md](../runbooks/scorecard-signed-releases-backfill.md).

## gh-attestation-repo invariant<a name="gh-attestation-repo-invariant"></a>

Every `gh attestation verify` invocation across workflows, scripts, and documentation — in fenced shell blocks and in inline code alike — must pass `--repo rvenutolo/linPEAS-flake`. Without the `--repo` pin, Sigstore returns any attestation matching the artifact digest, including one issued from a different repository — a trivial bypass.

Enforced by `scripts/check-gh-attestation-repo.sh`, with parsing in `scripts/_attestation_invocations.awk`. The lint joins backslash-continued shell invocations, then splits every source — runnable lines and backtick spans alike — into shell words, honouring single quotes, double quotes, and backslash escapes, and treating a backtick as a word delimiter rather than part of a word. A record runs from the `gh attestation verify` word triple to the next unquoted shell separator or comment, or to the end of the string. The pin satisfies the check only as a word `--repo` whose next word is the slug, or a word `--repo=<slug>`.

Binding the pin to a word position rather than to a substring is what stops text that merely sits near the command from vouching for it: a pin in a trailing comment, a pin belonging to a chained command, and a slug inside a quoted argument all leave the invocation unpinned. A record carrying the command plus at least one further word is always an invocation. A record holding the bare command name with no further word depends on where it came from: on a runnable line it is an unpinned invocation and is flagged, while inside a code span it is a prose mention and is ignored. A runnable line is inspected with its code spans removed, so a quoted occurrence is counted once, by the span scan.

Markdown is lexed before splitting. Fences are tracked by fence character and run length, so a backtick run cannot close a tilde fence; the info string is normalized to its first word with attribute punctuation stripped, so ```` ```{.sh} ```` reads as `sh`. A backtick fence whose info string contains a backtick is not a fence at all, so a line-leading inline code span cannot desynchronize fence tracking for the rest of the file. Fenced blocks (`sh`, `bash`, `shell`, `console`, `text`, or unlabeled) and four-space-indented blocks are shell source, and non-shell fences (mermaid, dot) are skipped entirely. Prose contributes only its code spans, matched by backtick run length so a doubled-backtick span carries its payload intact. A span left open at the end of a line continues onto the next and is abandoned at a blank line. Comment lines in workflows and scripts are skipped before the span scan. Wired as the `lint-workflow-security` CI job (member check `gh-attestation-repo`) and as a pre-commit hook.

A leading `#` inside a `console` or `text` fence is read as a shell comment, so an invocation shown after a root prompt is not inspected. Nothing in the line itself distinguishes a root prompt from ordinary prose, and treating every `#` as a prompt reports documentation prose that merely mentions the command as an unpinned invocation. The miss is preferred to that false positive, because a false positive blocks a correct commit while this gap only affects a shape no tracked doc uses: every invocation in this repository is shown either unprefixed or after a `$` prompt, both of which are inspected normally.

## cosign-identity-pinned invariant<a name="cosign-identity-pinned-invariant"></a>

Every `cosign verify` invocation across workflows, scripts, and shell-fenced documentation must pin BOTH `--certificate-identity` (or `--certificate-identity-regexp`) AND `--certificate-oidc-issuer`. The `nix run nixpkgs#cosign -- verify` shape is recognized as well.

Without identity pinning, cosign accepts any keyless Sigstore signature for the artifact digest — including one minted by a different workflow, branch, or OIDC issuer. The two flags bind verification to a specific signer chain.

Enforced by `scripts/check-cosign-identity-pinned.sh`. Wired as the `lint-workflow-security` CI job (member check `cosign-identity-pinned`) and as a pre-commit hook.
