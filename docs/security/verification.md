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
- `cross-registry-manifest-mismatch` — **security incident.** ghcr.io
    and docker.io serve different multi-arch manifests for the release
    tag. Identical bytes are published to both at release time, so a
    divergence means post-publication tag rewriting on one registry —
    typically a rollback to an older, still-validly-signed release,
    which no signature or attestation check can detect. Triage via
    [dockerhub-recovery.md](../runbooks/dockerhub-recovery.md).
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

Only `upstream-sri-drift` and `cross-registry-manifest-mismatch` (and to
a lesser extent `manifest-tag-drift`) warrant the "treat as security
incident" framing. Folding all reasons into a single failure body trains
the maintainer to skim-read auto-filed issues — exactly the wrong reflex
when the failure is a real SRI drift or a one-sided registry rollback.

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

Every `gh attestation verify` invocation across workflows, composite actions, scripts, nix modules, the justfile, and documentation — in fenced shell blocks and in inline code alike — must pass `--repo rvenutolo/linPEAS-flake`. Without the `--repo` pin, Sigstore returns any attestation matching the artifact digest, including one issued from a different repository — a trivial bypass.

Enforced by `scripts/check-gh-attestation-repo.sh`, with parsing in `scripts/_attestation_invocations.awk`. The lint joins backslash-continued shell invocations, then splits every source — runnable lines and backtick spans alike — into shell words, honouring single quotes, double quotes, and backslash escapes, and treating a backtick as a word delimiter rather than part of a word. A record runs from the `gh attestation verify` word triple to the next unquoted shell separator or comment, or to the end of the string. A redirection operator is not a separator — `2>&1`, `>&2`, and `&>f` keep the record open — so a pin written after a redirection still counts, while a bare `&` backgrounds the command and ends the record. The pin satisfies the check only as a word `--repo` or `-R` whose next word is the slug, or a word `--repo=<slug>`, `-R=<slug>`, or `-R<slug>` — the glued short form `gh` itself accepts.

Binding the pin to a word position rather than to a substring is what stops text that merely sits near the command from vouching for it: a pin in a trailing comment, a pin belonging to a chained command, and a slug inside a quoted argument all leave the invocation unpinned. A record carrying the command plus at least one further word is always an invocation. A record holding the bare command name with no further word depends on where it came from: on a runnable line it is an unpinned invocation and is flagged, while inside a code span it is a prose mention and is ignored. A runnable line is inspected with its code spans removed, so a quoted occurrence is counted once, by the span scan.

A quoted region is ordinarily literal word text, which is what shell means by it: `"a b"` is one argument. Where the quotes belong to the enclosing document rather than to shell — a YAML `run:` scalar, a nix `entry = "…"` attribute, an `eval` or `-c` argument — the payload is a command line, and reading it as one word would hide the invocation it carries. The lint re-parses a quoted region as a command source, in either quote character, when the text immediately before the opening quote marks command position: an attribute or mapping key whose value is a command (`run`, `entry`, `text`, `script`, `command`, `cmd`, `entrypoint`, `shell`) written with its `:` or `=`, the word `eval`, or a flag whose argument is a command (`--command`, with or without a glued `=`, or a short-option cluster ending in `c` — `-c`, `-ec`, `-lc`, `-xc` — where the command the cluster belongs to names a shell). A bare key word with no punctuation does not introduce a command, which is what keeps `npm run "…"` and `nix shell "…"` literal. Structural punctuation around the preceding text is stripped first, so the YAML flow forms `- {run: "…"}` and `["sh", "-c", "…"]` read the same as their block forms. The lookback for a `c` cluster reads the words of the command carrying it back to that command's start, and any of those words naming a shell, by its last path component, makes the cluster a command introducer. A subshell paren and a code-span backtick bound commands on both sides, so a shell before them cannot vouch for a cluster after them, and a cluster standing immediately after one opens its command and is not an introducer. A substitution paren (`$(`, `<(`, `>(`) produces a word in the enclosing command, so a lookback outside the substitution steps over it and keeps reading the enclosing command's own words — the interior is not read from there. A `c` cluster written inside a substitution reads its own command's words normally, unaffected by that outer skip, which is what keeps `$(bash -c '…')` a command source: `bash` is an ordinary same-depth word of the cluster's own command. The one exception to the outer skip is a command substitution standing as the enclosing command's first word: its direct words are read too, since its output becomes the command word, which is what keeps `$(command -v bash) -c '…'` a command source. That reads a shell wherever it stands in its own command, whether an option argument, an operand, an intervening substitution, or nothing at all separates it from the cluster, so `bash -x -c`, `bash -o pipefail -c`, `sh $(x) -c`, `bash $((1+1)) -c`, `env -i bash -c`, `/bin/sh -c`, `${pkgs.bash}/bin/bash -c`, and `docker run --entrypoint /bin/sh img -c` are all command sources, while the same cluster in a command naming no shell takes a pattern and its quoted argument stays literal word text. Reading past the `=` to the attribute name is what keeps a prose string such as a hook `description` literal. The payload also keeps its place in the enclosing word, so a slug inside a quoted argument still fails to pin the invocation it sits in.

A payload holding the bare command triple and nothing else is a mention rather than an invocation: a quoted string naming no artifact cannot be a verification, and reading one as an invocation would report a shell-carried triple such as `sh -c 'gh attestation verify'` as a violation. That scoping is withdrawn when the quoted region does not end its word: `eval 'gh attestation verify --repo rvenutolo/linPEAS-flake '"${ART}"` splits one command line across a quote boundary, so its payload is a fragment of a longer command line rather than a whole argument, and is judged as an invocation rather than a mention — which is what makes the pin inside it count. A fragment's own payloads inherit that judgement only where they sit at its end, so a complete quoted argument nested inside a fragment stays a mention. Scoping is withdrawn a second time for `eval`, which concatenates its arguments before executing them: a bare-triple payload introduced by `eval` and followed by a further word is judged an invocation, because the artifact can sit outside the quotes. A separator rather than a word follows nothing into the command, so that form stays a mention, and the withdrawal is scoped to `eval` alone — every other introducer passes its next word to the program rather than to the command line, which is what keeps a shell-carried bare triple such as `sh -c 'gh attestation verify' f` a mention.

The rule sees the shapes it names. An attribute outside that set still hides its payload. A `c` cluster no word of whose command names a recognized shell is not read as a command source, so an invocation written that way is missed. Three shapes reach that state: the shell is named through a variable, as in `$SHELL -c`; it is one outside the recognized set (`bash`, `sh`, `dash`, `ash`, `zsh`, `ksh`, `mksh`, `fish`, `su`, `runuser`); or the cluster opens its command with no word before it at all. A quoted expansion such as `bash "$(dirname x)/f" -c` is ordinary word text and keeps the shell in the cluster's own command. That miss is preferred to the false positive reading every `c` cluster carries: a match key such as `grep -Ec 'gh attestation verify …'` names the command plus a further word, and a payload with a further word past the bare triple is always judged an invocation, so that reading fails a correct file. Reading the whole command rather than only the cluster's own flags widens the introducer in one direction: a command naming a shell as an ordinary word while carrying a `c` cluster of its own has that cluster's argument read as a command line. Nothing in this repository writes that shape. A legacy backtick substitution standing as the command word, as in `` `command -v bash` -c '…' ``, is not read as a shell — a backtick is ambiguous between substitution and code span, and the miss is preferred to reading prose spans as command sources. A shell named only inside a nested substitution of a command-word substitution, as in `$($(sh)) -c '…'`, is not read either: the command-initial exception reads a group's direct words only, so a shell one substitution further in stays unread. A payload split across a backslash-continued line, or across a code span the markdown scan has already removed, reads as ending its word and stays mention-scoped. A double-quoted YAML scalar folded across source lines is read only to the end of its first line: backslash continuation is joined before splitting, YAML line folding is not. An attribute in the introducer set is read the same way whether its value is a command or prose about one, so prose that names the command and goes on to further words is judged an invocation exactly as a real one would be.

Markdown is lexed before splitting. Fences are tracked by fence character and run length, so a backtick run cannot close a tilde fence; the info string is normalized to its first word with attribute punctuation stripped, so ```` ```{.sh} ```` reads as `sh`. A backtick fence whose info string contains a backtick is not a fence at all, so a line-leading inline code span cannot desynchronize fence tracking for the rest of the file. Fenced blocks (`sh`, `bash`, `shell`, `console`, `text`, or unlabeled) and four-space-indented blocks are shell source, and non-shell fences (mermaid, dot) are skipped entirely. Prose contributes only its code spans, matched by backtick run length so a doubled-backtick span carries its payload intact. A span left open at the end of a line continues onto the next and is abandoned at a blank line. A line whose first non-space character is `#` is a comment wherever the line is shell source — a script, a workflow, a fenced shell block, or an indented code block — and is skipped before the span scan, so a backticked command inside it stays prose. Markdown prose is not shell source, so a `#` there opens a heading and its code spans are inspected normally. Wired as the `lint-workflow-security` CI job (member check `gh-attestation-repo`) and as a pre-commit hook.

The uniform comment rule means an invocation shown after a root `#` prompt is not inspected. Nothing in the line itself distinguishes a root prompt from ordinary prose, and treating every `#` as a prompt reports documentation that merely mentions the command as an unpinned invocation. The miss is preferred to that false positive, because a false positive blocks a correct commit while this gap only affects a shape no tracked doc uses: every invocation in this repository is shown either unprefixed or after a `$` prompt, both of which are inspected normally.

## cosign-identity-pinned invariant<a name="cosign-identity-pinned-invariant"></a>

Every `cosign verify*` invocation (`verify`, `verify-blob`, `verify-attestation`, `verify-blob-attestation`) across workflows, scripts, and shell-fenced documentation must pin BOTH `--certificate-identity` (or `--certificate-identity-regexp`) AND `--certificate-oidc-issuer`. The `nix run nixpkgs#cosign -- verify` shape is recognized as well.

Without identity pinning, cosign accepts any keyless Sigstore signature for the artifact digest — including one minted by a different workflow, branch, or OIDC issuer. The two flags bind verification to a specific signer chain.

Enforced by `scripts/check-cosign-identity-pinned.sh`. Wired as the `lint-workflow-security` CI job (member check `cosign-identity-pinned`) and as a pre-commit hook.
