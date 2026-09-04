# Verification walkthrough

How to verify a release of this wrapper yourself. None of this trusts the Pages site you are reading.

<!-- mdformat-toc start --slug=github --maxlevel=3 --minlevel=2 -->

- [Tools needed](#tools-needed)
- [Verify the OCI image's build provenance](#verify-the-oci-images-build-provenance)
- [Multi-arch attestations](#multi-arch-attestations)
- [Verify the weekly parity check is current](#verify-the-weekly-parity-check-is-current)
- [Bump-script integrity guards](#bump-script-integrity-guards)
- [verify-latest-release upstream parity](#verify-latest-release-upstream-parity)
- [verify-latest-release failure attribution](#verify-latest-release-failure-attribution)
  - [Ladder coverage is linted](#ladder-coverage-is-linted)
- [Gitleaks secret scanning](#gitleaks-secret-scanning)
- [TruffleHog secret scanning](#trufflehog-secret-scanning)
- [Dependency review](#dependency-review)
- [OCI image CVE scan (Trivy)](#oci-image-cve-scan-trivy)
- [OCI image CVE scan (Grype)](#oci-image-cve-scan-grype)
- [SBOM attestation](#sbom-attestation)
- [Cosign keyless signatures](#cosign-keyless-signatures)
  - [Identity pinning](#identity-pinning)
  - [User-facing verification commands](#user-facing-verification-commands)
- [Release-asset blob signatures](#release-asset-blob-signatures)
- [Release-asset provenance sidecars](#release-asset-provenance-sidecars)
- [gh-attestation-repo invariant](#gh-attestation-repo-invariant)
  - [Word-position pinning](#word-position-pinning)
  - [Quoted regions read as command sources](#quoted-regions-read-as-command-sources)
  - [Bare-triple payloads: mention or invocation](#bare-triple-payloads-mention-or-invocation)
  - [Recognized shells and known misses](#recognized-shells-and-known-misses)
  - [Markdown lexing](#markdown-lexing)
- [cosign-identity-pinned invariant](#cosign-identity-pinned-invariant)

<!-- mdformat-toc end -->

## Tools needed<a name="tools-needed"></a>

- `gh` (GitHub CLI) ≥ 2.49 — the upstream release that introduced
    `gh attestation verify`; `gh release download` fetches the signed
    release assets.
- `cosign` ≥ 3.0 — `cosign verify` for image signatures and
    `cosign verify-blob` for the `.sigstore` release-asset bundles,
    which the release pipeline produces with cosign 3.x (an older 2.x
    client is not guaranteed to read its bundle format).
- `docker` with `buildx` — `docker buildx imagetools inspect … --raw`
    resolves the per-arch image digest from the multi-arch index.
- `jq` — reads that digest out of the raw index.

Either signing toolchain alone is enough to verify the image once the digest
is resolved: `gh attestation verify` and `cosign verify` check different
signatures over the same digest.

## Verify the OCI image's build provenance<a name="verify-the-oci-images-build-provenance"></a>

```bash
DIGEST=$(docker buildx imagetools inspect \
  ghcr.io/rvenutolo/linpeas:{{ dashboard.release.latest_tag or "<tag>" }} --raw |
  jq --raw-output '.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64").digest')
gh attestation verify \
  "oci://ghcr.io/rvenutolo/linpeas@${DIGEST}" \
  --repo rvenutolo/linPEAS-flake
```

The first command resolves the `linux/amd64` arch-image digest from the
multi-arch index (substitute `arm64` as needed) — attestations are
per-arch, so the verify must target that digest, not the tag (see
[Multi-arch attestations](#multi-arch-attestations)). This proves the
image was built by this repo's `release-on-bump.yml` workflow
run. `--repo` pins the attestation to this repository, so a bundle issued by
any other repo cannot satisfy it.

## Multi-arch attestations<a name="multi-arch-attestations"></a>

The published OCI image is a multi-arch manifest covering `linux/amd64`
and `linux/arm64`. **SLSA attestations are per-arch**, not per-manifest.
This means:

- `gh attestation verify oci://docker.io/rvenutolo/linpeas:<tag> --repo rvenutolo/linPEAS-flake`
    fails with a not-found error: the tag resolves to the manifest index,
    which carries no attestation. The `RepoDigests` value recorded by a
    tag pull is that same index digest, so it fails the same way. Resolve
    the arch-image digest from the index via
    `docker buildx imagetools inspect <ref> --raw` and verify that
    digest instead.
- Each arch image was independently built from the same commit of this
    repo, so the attestations cover the same source provenance.
- The manifest index itself is **not** attested. An attacker with push
    to either registry could repoint the manifest at unattested images;
    the verify step in `release-on-bump.yml` would catch this at release
    time, but consumers who only verify the manifest pointer (not the
    arch image) would miss it. Always verify against the resolved
    arch-image digest.

## Verify the weekly parity check is current<a name="verify-the-weekly-parity-check-is-current"></a>

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

1. Asset URL must start with
    `https://github.com/peass-ng/PEASS-ng/releases/download/`. Hard fail.
1. GitHub-API `.digest` field never silently skipped. Absent or
    non-`sha256:` prefix is a hard fail.
1. Pin file written via `make_temp` (`scripts/lib/temp.sh`) + `mv` (atomic).
    Never `>`, and never a bare `mktemp` — the script-hygiene lint rejects that
    shape under `scripts/`; the guarded helper in `scripts/lib/temp.sh` holds
    the one sanctioned bare invocation.
1. Every `gh api` call in `scripts/*.sh` must pass
    `--header "X-GitHub-Api-Version: 2022-11-28"`. Apply to any new
    security-sensitive GitHub-REST caller.

The bump-script tokens of guards 1–3 are lint-enforced by
`scripts/check-bump-script-integrity.sh` (regex-presence over
`scripts/bump-linpeas.sh`); the tree-wide bare-`mktemp` ban in guard 3
by `scripts/check-guard-exit-code.sh`; guard 4 by
`scripts/check-gh-api-version-header.sh`. All three run in the
`lint-script-hygiene` CI job; the first and last also run as pre-commit
hooks.

## verify-latest-release upstream parity<a name="verify-latest-release-upstream-parity"></a>

The weekly verify cron re-fetches the pinned `linpeas.sh` URL, recomputes the SRI
hash via `openssl dgst -sha256 -binary <file> | base64 --wrap=0`, compares against
`linpeas-pin.json`. Failure = security incident.

## verify-latest-release failure attribution<a name="verify-latest-release-failure-attribution"></a>

`verify-latest-release.yml`'s notify body distinguishes failure
reasons via per-step `id:` outcomes mapped to a `reason` token by
the `attribute failure reason` step. Reasons:

- `upstream-sri-drift` — **security incident.** Upstream
    `linpeas.sh` SHA-256 no longer matches the pinned SRI.
- `manifest-tag-drift` — `:latest` no longer resolves to the same
    manifest as `:VERSION` on ghcr.io or docker.io.
- `cross-registry-manifest-mismatch` — **security incident.** ghcr.io
    and docker.io serve different multi-arch manifests for the release
    tag. Identical bytes are published to both at release time, so a
    divergence means post-publication tag rewriting on one registry —
    typically a rollback to an older, still-validly-signed release,
    which no signature or attestation check can detect. Triage via
    [dockerhub-recovery.md](../runbooks/dockerhub-recovery.md).
- `ghcr-attest-failed` / `hub-attest-failed` /
    `pin-attest-failed` — attestation
    verification failed for a specific artifact. Either tampering or a
    Sigstore TUF trust-root rotation lag on the runner image; re-run the
    cron 24h later to distinguish before treating it as tampering.
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
    `*-attest-failed` reasons and subject to the same re-run-first caveat.
- `unattributed` — the job failed but no ladder arm matched the failed
    step. The ladder has a gap: the failure is real and unexplained, so
    triage it by hand and fix the attribution step. This is the token to
    watch for after adding a verification step without wiring its
    `id:` into the ladder.
- `unknown` — the `verify` job produced no `reason` output at all,
    which happens when it is cancelled or skipped before the attribution
    step runs. Not a verification result; re-run the cron.

`upstream-sri-drift` and `cross-registry-manifest-mismatch` warrant the
"treat as security incident" framing outright; the `*-attest-failed`
family and `images-cosign-failed` warrant it once a 24h re-run has ruled
out trust-root rotation lag, with `manifest-tag-drift` a step below.
Folding all reasons into a single failure body trains
the maintainer to skim-read auto-filed issues — exactly the wrong reflex
when the failure is a real SRI drift or a one-sided registry rollback.

This pattern is the project default for every cron-notify caller: each
must attribute distinct failure reasons to distinct issue-body wording.
Alert fatigue is a security risk.

### Ladder coverage is linted<a name="ladder-coverage-is-linted"></a>

The step ids, the attribution step's `env:` block, the `elif` ladder,
and the reason list above are four hand-synced copies of one set.
`scripts/check-verify-reason-ladder.sh` binds them: every `id:`-carrying
step in the `verify` job is referenced by a `steps.<id>.outcome` entry
in the attribution `env:`, every such env var is read by the ladder,
every `reason` token the ladder emits appears in the list above, and the
ladder's branch order matches the steps' execution order — the order the
"first failed step wins" rule depends on.

Without that binding, a step added without a ladder branch reports
`unattributed`, whose documented meaning is a gap in the ladder —
so a real verification failure would be auto-filed as a self-diagnosed
tooling bug, and the triage reflex would be wrong for exactly the case
that matters.

A step that legitimately carries an `id:` without being a verification
outcome is excluded with a `# reason-ladder-exempt: <reason>` comment on
the same line as its `id:`. An empty rationale is drift, not an
exemption.

## Gitleaks secret scanning<a name="gitleaks-secret-scanning"></a>

`gitleaks.yml` scans the full git history (`fetch-depth: 0`) on push to
main, every PR, a weekly Friday cron, and manual dispatch. Required
check named `gitleaks` in the `protect-main` ruleset.

- Uses only `secrets.GITHUB_TOKEN` — PR-triggered workflow secret
    allowlist invariant holds.
- New leaked-secret finding = security incident. Triage:
    rotate → purge with `git filter-repo` → force-push. The force-push
    needs the `protect-main` ruleset set to `disabled` via `gh api` for
    the duration: its `bypass_actors` list is empty, so the
    `non_fast_forward` rule blocks a repository admin as well. Re-sign
    the rewritten commits before pushing — history rewriting drops the
    original signatures and `required_signatures` rejects unsigned
    objects — and expect `protect-main-drift-check` to stay red until
    the ruleset is re-enabled.
- Vendor `gitleaks/*` is in the `allowed_actions` allowlist; do not
    remove without replacing the workflow.

## TruffleHog secret scanning<a name="trufflehog-secret-scanning"></a>

`trufflehog.yml` scans the full git history (`fetch-depth: 0`) on push
to main, every PR, a weekly Friday cron, and manual dispatch. Required
check named `trufflehog` in the `protect-main` ruleset. It runs with
`extra_args: --only-verified`, so a finding is a credential TruffleHog
reached the issuing provider to confirm is live — not a pattern match.

Gitleaks and TruffleHog are a deliberate pair: they carry different
detector sets, and a secret shape one misses is the reason the other
runs. Neither substitutes for the other, and dropping either needs a
[security-review entry](https://github.com/rvenutolo/linPEAS-flake/blob/main/CONTRIBUTING.md#security-review-entries).

- Uses only `secrets.GITHUB_TOKEN` — PR-triggered workflow secret
    allowlist invariant holds.
- A verified finding is a live credential and therefore a security
    incident. Triage is the same as for gitleaks:
    rotate → purge with `git filter-repo` → force-push behind a
    temporarily disabled `protect-main` ruleset, with the same
    re-signing requirement.
    Rotate first — the secret is confirmed valid, so history rewriting
    is the slower half of the response.
- Vendor `trufflesecurity/*` is in the `allowed_actions` allowlist; do
    not remove without replacing the workflow.

## Dependency review<a name="dependency-review"></a>

`dependency-review.yml` runs on every PR via
`actions/dependency-review-action`. Required check named
`dependency-review`. `fail-on-severity: moderate`,
`comment-summary-in-pr: on-failure`.

- The repo carries no traditional package manifests, so the action
    mostly scans `.github/workflows/**` `uses:` against the GitHub
    Advisory DB + license policy. Belt-and-braces backup to
    SHA-pinning + Renovate + zizmor.
- If a future PR adds a real manifest (npm/cargo/pip/etc.), the action
    begins scanning it without any workflow change.

## OCI image CVE scan (Trivy)<a name="oci-image-cve-scan-trivy"></a>

`image-cve-scan.yml`'s `image-cve-scan-trivy` job (weekly cron +
path-filtered push to `main` + dispatch) uploads SARIF
(CRITICAL + HIGH) to the Security tab, then
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
    of erroring under `set -Eeuo pipefail`. Revisit the threshold if
    GitHub revises the CVSS-to-bucket mapping.

## OCI image CVE scan (Grype)<a name="oci-image-cve-scan-grype"></a>

`image-cve-scan.yml`'s `image-cve-scan-grype` job (weekly cron +
path-filtered push to `main` + dispatch) uploads SARIF (fixed-only
findings, all severities; results below HIGH carry `warning` level
because `severity-cutoff: high` sets the result level rather than
filtering) to the Security tab under
category `grype-image-cve`, using Grype as a second-opinion scanner
alongside Trivy. The job fails (and emits a notify issue) on a CRITICAL
finding, and — like Trivy — on any infrastructure failure ahead of the
count step; the two notify jobs below distinguish the cases. Advisory only — not
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

## Release-asset blob signatures<a name="release-asset-blob-signatures"></a>

Each primary release asset — the pin file and each SBOM the release
publishes — has a sibling `.sigstore` bundle:

- `linpeas-pin.json` + `linpeas-pin.json.sigstore`
- `linpeas-image-amd64.cdx.json` + `linpeas-image-amd64.cdx.json.sigstore`
- `linpeas-image-arm64.cdx.json` + `linpeas-image-arm64.cdx.json.sigstore`

Download both files for the asset you want to verify, then run
`cosign verify-blob` with the same identity pin used for image
signatures:

```bash
gh release download <tag> \
  --repo rvenutolo/linPEAS-flake \
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

Every primary release asset — `linpeas-pin.json` and the per-arch
CycloneDX SBOMs — is published alongside a sibling
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

The contract is: for every primary `<asset>` in a release — the pin
file and each SBOM the release publishes — both `<asset>.sigstore`
(cosign signature bundle) and `<asset>.intoto.jsonl` (build provenance
bundle) MUST be present; the sidecars themselves carry no further
sidecars.
A release missing either sidecar is a regression. Nothing in-tree
asserts this contract — the weekly parity cron's reason ladder covers
the `.sigstore` blob signatures only, and the enforcement matrix records
no enforcer for the sidecar rows — so detection is indirect: a missing
sidecar surfaces as a drop in the Scorecard Signed-Releases score. The
recovery procedure lives in
[docs/runbooks/scorecard-signed-releases-backfill.md](../runbooks/scorecard-signed-releases-backfill.md).

## gh-attestation-repo invariant<a name="gh-attestation-repo-invariant"></a>

Every `gh attestation verify` invocation across workflows, composite actions, scripts, nix modules, the justfile, and documentation — in fenced shell blocks and in inline code alike — must pass `--repo rvenutolo/linPEAS-flake`. `gh attestation verify` requires either `--owner` or `--repo`, so an unpinned invocation does not run at all. The bypass the pin forecloses is the `--owner`-only spelling: it binds verification to the account, so an attestation issued by any other repository under `rvenutolo` satisfies it. `--repo` narrows that to this repository, so a bundle issued elsewhere fails.

Enforced by `scripts/check-gh-attestation-repo.sh`, with parsing in `scripts/_attestation_invocations.awk`. The lint splits every source into shell words — runnable lines after joining their backslash continuations, backtick spans as written — honouring single quotes, double quotes, and backslash escapes, and treating a backtick as a word delimiter rather than part of a word. A record runs from the `gh attestation verify` word triple to the next unquoted shell separator or comment, or to the end of the string. A redirection operator is not a separator — `2>&1`, `>&2`, and `&>f` keep the record open — so a pin written after a redirection still counts, while a bare `&` backgrounds the command and ends the record. The pin satisfies the check only as a word `--repo` or `-R` whose next word is the slug, or a word `--repo=<slug>`, `-R=<slug>`, or `-R<slug>` — the glued short form `gh` itself accepts. Wired as the `lint-workflow-security` CI job (member check `gh-attestation-repo`) and as a pre-commit hook.

### Word-position pinning<a name="word-position-pinning"></a>

Binding the pin to a word position rather than to a substring is what stops text that merely sits near the command from vouching for it: a pin in a trailing comment, a pin belonging to a chained command, and a slug inside a quoted argument all leave the invocation unpinned. A record carrying the command plus at least one further word is always an invocation. A record holding the bare command triple with no further word depends on where it came from: on a runnable line it is an unpinned invocation and is flagged, while inside a code span it is a prose mention and is ignored. A runnable line is inspected with its code spans removed, so a quoted occurrence is counted once, by the span scan.

### Quoted regions read as command sources<a name="quoted-regions-read-as-command-sources"></a>

A quoted region is ordinarily literal word text, which is what shell means by it: `"a b"` is one argument. Where the quotes belong to the enclosing document rather than to shell — a YAML `run:` scalar, a nix `entry = "…"` attribute, an `eval` or `-c` argument — the payload is a command line, and reading it as one word would hide the invocation it carries.

The lint re-parses a quoted region as a command source, in either quote character, when the text immediately before the opening quote marks command position:

- an attribute or mapping key whose value is a command — `run`, `entry`, `text`, `script`, `command`, `cmd`, `entrypoint`, `shell` — written with its `:` or `=`;
- the word `eval`;
- a flag whose argument is a command: `--command`, with or without a glued `=`, or a short-option cluster ending in `c` (`-c`, `-ec`, `-lc`, `-xc`) where the command the cluster belongs to names a shell.

A bare key word with no punctuation does not introduce a command, which is what keeps `npm run "…"` and `nix shell "…"` literal. Structural punctuation around the preceding text is stripped first, so the YAML flow forms `- {run: "…"}` and `["sh", "-c", "…"]` read the same as their block forms. Reading past the `=` to the attribute name is what keeps a prose string such as a hook `description` literal. The payload also keeps its place in the enclosing word, so a slug inside a quoted argument still fails to pin the invocation it sits in.

#### The `c`-cluster lookback

The lookback for a `c` cluster reads the words of the command carrying it back to that command's start, and any of those words naming a shell — by its last path component, after structural flow punctuation is stripped — makes the cluster a command introducer. A subshell paren and a code-span backtick bound commands on both sides, so a shell before them cannot vouch for a cluster after them, and a cluster standing immediately after one opens its command and is not an introducer.

A substitution paren (`$(`, `<(`, `>(`) produces a word in the enclosing command, so a lookback outside the substitution steps over it and keeps reading the enclosing command's own words — the interior is not read from there. A `c` cluster written inside a substitution reads its own command's words normally, unaffected by that outer skip, which is what keeps `$(bash -c '…')` a command source: `bash` is an ordinary same-depth word of the cluster's own command. The one exception to the outer skip is a command substitution standing as the enclosing command's first word: its direct words are read too, since its output becomes the command word, which is what keeps `$(command -v bash) -c '…'` a command source.

That reads a shell wherever it stands in its own command, whether an option argument, an operand, an intervening substitution, or nothing at all separates it from the cluster. All of these are command sources:

- `bash -x -c`
- `bash -o pipefail -c`
- `sh $(x) -c`
- `bash $((1+1)) -c`
- `env -i bash -c`
- `/bin/sh -c`
- `${pkgs.bash}/bin/bash -c`
- `docker run --entrypoint /bin/sh img -c`

The same cluster in a command naming no shell takes a pattern, and its quoted argument stays literal word text.

### Bare-triple payloads: mention or invocation<a name="bare-triple-payloads-mention-or-invocation"></a>

A payload holding the bare command triple and nothing else is a mention rather than an invocation: a quoted string naming no artifact cannot be a verification, and reading one as an invocation would report a shell-carried triple such as `sh -c 'gh attestation verify'` as a violation. That scoping is withdrawn when the quoted region does not end its word: `eval 'gh attestation verify --repo rvenutolo/linPEAS-flake '"${ART}"` splits one command line across a quote boundary, so its payload is a fragment of a longer command line rather than a whole argument, and is judged as an invocation rather than a mention — which is what makes the pin inside it count. A fragment's own payloads inherit that judgement only where they sit at its end, so a complete quoted argument nested inside a fragment stays a mention. Scoping is withdrawn a second time for `eval`, which concatenates its arguments before executing them: a bare-triple payload introduced by `eval` and followed by a further word is judged an invocation, because the artifact can sit outside the quotes. A separator rather than a word follows nothing into the command, so that form stays a mention, and the withdrawal is scoped to `eval` alone — every other introducer passes its next word to the program rather than to the command line, which is what keeps a shell-carried bare triple such as `sh -c 'gh attestation verify' f` a mention.

### Recognized shells and known misses<a name="recognized-shells-and-known-misses"></a>

The rule sees the shapes it names. An attribute outside that set still hides its payload. A `c` cluster no word of whose command names a recognized shell is not read as a command source, so an invocation written that way is missed. Three shapes reach that state: the shell is named through a variable, as in `$SHELL -c`; it is one outside the recognized set (`bash`, `sh`, `dash`, `ash`, `zsh`, `ksh`, `mksh`, `fish`, `su`, `runuser`); or the cluster opens its command with no word before it at all. A quoted expansion such as `bash "$(dirname x)/f" -c` is ordinary word text and keeps the shell in the cluster's own command. That miss is preferred to the false positive reading every `c` cluster carries: a match key such as `grep -Ec 'gh attestation verify …'` names the command plus a further word, and a payload with a further word past the bare triple is always judged an invocation, so that reading fails a correct file. Reading the whole command rather than only the cluster's own flags widens the introducer in one direction: a command naming a shell as an ordinary word while carrying a `c` cluster of its own has that cluster's argument read as a command line. Nothing in this repository writes that shape. A legacy backtick substitution standing as the command word, as in `` `command -v bash` -c '…' ``, is not read as a shell — a backtick is ambiguous between substitution and code span, and the miss is preferred to reading prose spans as command sources. A shell named only inside a nested substitution of a command-word substitution, as in `$($(sh)) -c '…'`, is not read either: the command-initial exception reads a group's direct words only, so a shell one substitution further in stays unread. A payload whose own text is split across a backslash-continued line, or across a code span the markdown scan has already removed, reads as ending its word and stays mention-scoped. A double-quoted YAML scalar folded across source lines is read only to the end of its first line: backslash continuation is joined before splitting, YAML line folding is not. An attribute in the introducer set is read the same way whether its value is a command or prose about one, so prose that names the command and goes on to further words is judged an invocation exactly as a real one would be.

### Markdown lexing<a name="markdown-lexing"></a>

Markdown is lexed before splitting. Fences are tracked by fence character and run length, so a backtick run cannot close a tilde fence; the info string is normalized to its first word with attribute punctuation stripped, so ```` ```{.sh} ```` reads as `sh`. A backtick fence whose info string contains a backtick is not a fence at all, so a line-leading inline code span cannot desynchronize fence tracking for the rest of the file. Fenced blocks (`sh`, `bash`, `shell`, `console`, `text`, or unlabeled) and indented (four-space or tab) code blocks are shell source, and non-shell fences (mermaid, dot) are skipped entirely. Prose contributes only its code spans, matched by backtick run length so a doubled-backtick span carries its payload intact. A prose span left open at the end of a line continues onto the next and is abandoned at a blank line or at end of file; on a runnable line the open span's text is returned to that line's own runnable text instead, so an unterminated backtick cannot swallow the lines after it. A line whose first non-space character is `#` is a comment wherever the line is shell source — a script, a workflow, a fenced shell block, or an indented code block — and is skipped before the span scan, so a backticked command inside it stays prose. Markdown prose is not shell source, so a `#` there opens a heading and its code spans are inspected normally.

The uniform comment rule means an invocation shown after a root `#` prompt is not inspected. Nothing in the line itself distinguishes a root prompt from ordinary prose, and treating every `#` as a prompt reports documentation that merely mentions the command as an unpinned invocation. The miss is preferred to that false positive, because a false positive blocks a correct commit while this gap only affects a shape no tracked doc uses: every invocation in this repository is shown either unprefixed or after a `$` prompt, both of which are inspected normally.

## cosign-identity-pinned invariant<a name="cosign-identity-pinned-invariant"></a>

Every `cosign verify*` invocation (`verify`, `verify-blob`, `verify-attestation`, `verify-blob-attestation`) across workflows, scripts, and shell-fenced documentation must pin BOTH `--certificate-identity` (or `--certificate-identity-regexp`) AND `--certificate-oidc-issuer`. The `nix shell .#cosign --command cosign -- verify` shape (a `cosign` word, an optional `--`, then the subcommand) is recognized as well.

Without identity pinning, cosign accepts any keyless Sigstore signature for the artifact digest — including one minted by a different workflow, branch, or OIDC issuer. The two flags bind verification to a specific signer chain.

Enforced by `scripts/check-cosign-identity-pinned.sh`. Wired as the `lint-workflow-security` CI job (member check `cosign-identity-pinned`) and as a pre-commit hook.
