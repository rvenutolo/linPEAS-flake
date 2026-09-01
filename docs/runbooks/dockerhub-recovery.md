# Docker Hub recovery runbook

Steps to recover from a half-published release where one registry
(`docker.io` or `ghcr.io`) accepted a per-arch push but the other
failed, leaving an orphan arch-suffixed tag that a naive retry of
`release-on-bump.yml` would silently overwrite, invalidating any
attestations and signatures already issued over the original bytes —
the failing arch's attest steps never ran, but the sibling arch's job
may have completed fully before the failure.

This runbook is referenced from the auto-filed
`release-on-bump-failure` issue body. The issue body intentionally
links here rather than embedding the snippets inline, so:

- The snippets stay correct (JSON construction via `jq -n` is
    quote-safe, unlike shell-interpolated JSON).
- The procedure is one file to update if Docker Hub's API contract
    changes, not N copies across the workflow.

<!-- mdformat-toc start --slug=github --maxlevel=3 --minlevel=2 -->

- [When this applies](#when-this-applies)
- [Prerequisites](#prerequisites)
- [Step-by-step](#step-by-step)
  - [1. Delete the GitHub release (re-push path only)](#1-delete-the-github-release-re-push-path-only)
  - [2. Delete the orphan docker.io arch tag](#2-delete-the-orphan-dockerio-arch-tag)
  - [3. Re-trigger the release pipeline](#3-re-trigger-the-release-pipeline)
  - [4. Confirm green end-to-end](#4-confirm-green-end-to-end)
- [Common Docker Hub failure modes](#common-docker-hub-failure-modes)
- [DOCKERHUB_TOKEN split (RW + DELETE)](#dockerhub_token-split-rw--delete)
- [Notify-body parity invariant](#notify-body-parity-invariant)

<!-- mdformat-toc end -->

## When this applies<a name="when-this-applies"></a>

The push loop inside `release-on-bump.yml` per-arch jobs runs
`docker.io` first, then `ghcr.io`. The two failure modes are:

- **docker.io push failed.** Nothing was pushed to either registry
    for that arch, so that arch needs no registry-side cleanup; only the
    GitHub release needs deleting before the retry (the tag stays — see
    step 1).
- **ghcr.io push failed after docker.io succeeded.** docker.io has
    the arch-suffixed tag (`{version}-{arch}`) but ghcr.io does not.
    The `manifest` job is skipped, so neither registry has the
    unsuffixed `{version}` or `:latest` tags. Delete the orphan
    docker.io arch tag before retrying: the push itself would succeed
    and silently overwrite it, replacing bytes a prior attestation or
    signature may already reference and leaving the retry's digests
    ambiguous.

## Prerequisites<a name="prerequisites"></a>

- A Docker Hub access token with **Delete** scope. Use the
    `DOCKERHUB_TOKEN_DELETE` repository secret value
    (the `_RW` token returns `401` on the tag-delete endpoint).
    Fetch the secret value via the Docker Hub UI or your local
    secret vault — **do not** print `gh secret` values inside the
    auto-filed issue body.
- `DOCKERHUB_USERNAME` matching the repo owner (`rvenutolo`).
- A failing run identified in the `release-on-bump-failure` issue —
    record `VERSION` (the pin version, e.g. `20260516-deadbee`) and
    `ARCH` (`amd64` or `arm64`) before starting.

## Step-by-step<a name="step-by-step"></a>

### 1. Delete the GitHub release (re-push path only)<a name="1-delete-the-github-release-re-push-path-only"></a>

**Skip this step if you will re-run with `force-republish`** (step 3,
first bullet). On that path the `image-amd64`, `image-arm64`, `manifest`,
`changelog`, and `verify` jobs re-run against the current pin while the `release` job's
release-creation step stays gated by the "tag exists" guard, so the
release and its assets survive and nothing needs deleting. The
`release` job itself still runs. Its
`sign pin file (cosign sign-blob, keyless)` step is ungated and
re-uploads `linpeas-pin.json.sigstore` with `--clobber`, which is how
this path recovers a missing sidecar.

Delete only when recovering by landing a retrigger PR (step 3, second
bullet). Release-creation is gated on the release not existing (a
`gh release view` probe, surfaced as the `tag-exists` output), so an
orphan release left in place makes the re-push skip release creation, and
skips `image-amd64`, `image-arm64`, `manifest`, `changelog` and
`verify` as well (the same five jobs `force-republish` re-runs),
leaving the recovery incomplete.

```bash
VERSION="<pin-version>"            # e.g. 20260516-deadbee
gh release delete "${VERSION}" \
  --repo rvenutolo/linPEAS-flake \
  --yes
```

Do not add `--cleanup-tag`: the `release-tag-protection` ruleset
blocks tag deletion with no bypass actors, so the tag delete errors
and the command fails. The tag survives, still pointing at the
original pin commit, and release creation reuses it — an existing
tag's commit wins over the step's `--target` pin, so the re-created
release attaches to that original commit while the retry's
attestations record the retrigger SHA.

### 2. Delete the orphan docker.io arch tag<a name="2-delete-the-orphan-dockerio-arch-tag"></a>

Only required if `ghcr.io` failed after `docker.io` succeeded. Skip
to step 3 otherwise.

The simplest path is the Docker Hub web UI: navigate to
[`rvenutolo/linpeas` tags](https://hub.docker.com/r/rvenutolo/linpeas/tags),
find `{VERSION}-{ARCH}`, click "Delete".

For automation / scripted recovery, use the API:

```bash
DOCKERHUB_USERNAME=rvenutolo
DOCKERHUB_TOKEN_DELETE="<paste DOCKERHUB_TOKEN_DELETE value>"
VERSION="<pin-version>"
ARCH="<amd64 or arm64>"

# Build a quote-safe JSON body via jq -n --arg. Shell-interpolated
# JSON construction breaks when the password contains a single quote
# or backslash; `jq -n` guarantees correct escaping.
TOKEN=$(curl --fail --silent --show-error \
    --request POST 'https://hub.docker.com/v2/users/login' \
    --header 'Content-Type: application/json' \
    --data "$(jq --null-input \
        --arg u "${DOCKERHUB_USERNAME}" \
        --arg p "${DOCKERHUB_TOKEN_DELETE}" \
        '{username:$u, password:$p}')" \
  | jq --raw-output .token)

curl --fail --silent --show-error \
  --request DELETE \
  --header "Authorization: JWT ${TOKEN}" \
  "https://hub.docker.com/v2/repositories/${DOCKERHUB_USERNAME}/linpeas/tags/${VERSION}-${ARCH}/"
```

### 3. Re-trigger the release pipeline<a name="3-re-trigger-the-release-pipeline"></a>

Either:

- Dispatch the workflow from the Actions UI — the **Run workflow**
    button, i.e. `workflow_dispatch` — if the pin commit is still `HEAD`
    on `main`, setting `force-republish: true` so the image, manifest,
    verify, and changelog jobs run for the current pin even though the GitHub
    release already exists. **"Re-run jobs" is not a substitute:** it
    replays the original run's inputs and cannot set a new one, so on a
    push-triggered run `force-republish` stays false, `tag-exists` stays
    true, and all five jobs skip — the recovery looks green while doing
    nothing. The `release` job's release-creation step stays gated by the
    "tag exists" guard, so the existing release assets are preserved — if
    the release itself must be recreated, delete it first, then
    dispatch. This route is faster and leaves no retrigger commit
    behind, OR

- Open a PR that touches `linpeas-pin.json` itself with a
    prettier-stable edit (one blank line between two properties survives
    `treefmt`; other whitespace changes are reverted and fail the
    `flake-check` formatting gate) and a `chore: retrigger release`
    subject. `main` accepts no direct push — the `protect-main` ruleset
    has no bypass actors — so the commit lands only after the required
    checks pass. The workflow's `push` trigger filters on that path, so
    an empty commit or an edit to any other file starts nothing.

### 4. Confirm green end-to-end<a name="4-confirm-green-end-to-end"></a>

Watch the next `release-on-bump` run finish green. Specifically
confirm:

- `release` published a new release (or kept the existing one with
    `force-republish`).
- `preflight` emitted `image-mode=full`. On the recovery paths above it
    performs no registry probe — the state classification only runs in
    backfill mode, where `backfill-tag` is non-empty.
- `image-amd64` and `image-arm64` both pushed clean to docker.io and
    ghcr.io.
- `manifest` built and pushed.
- `changelog` re-ran, which it does on the `force-republish` path used
    above.
- `verify` passed per-arch attestation re-verify, manifest re-resolution,
    and `:latest` matches `:VERSION` per-arch digests.

Those are the seven jobs the workflow's own failure issue enumerates (the
two per-arch image jobs share a bullet above), so a green run means all
seven, not just the ones Docker Hub touches.

Close the `release-on-bump-failure` issue with a one-line root-cause
comment (e.g., `transient: docker.io 502 on push, retry green`).

## Common Docker Hub failure modes<a name="common-docker-hub-failure-modes"></a>

**Token expired or revoked.** Rotate `DOCKERHUB_TOKEN_RW` (and/or `DOCKERHUB_TOKEN_DELETE` independently) at <https://hub.docker.com/settings/security>, then `gh secret set DOCKERHUB_TOKEN_RW`.

**Username mismatch.** `DOCKERHUB_USERNAME` must equal the owner segment of the `rvenutolo/linpeas` repo path.

**Docker Hub partial outage.** Manual re-run via `workflow_dispatch` is usually enough; if multiple retries fail with the same shape, check <https://status.docker.com>.

## DOCKERHUB_TOKEN split (RW + DELETE)<a name="dockerhub_token-split-rw--delete"></a>

- **`DOCKERHUB_TOKEN_RW`** — Read, Write. Used by `release-on-bump.yml`.
- **`DOCKERHUB_TOKEN_DELETE`** — Read, Write, Delete. Used by
    `dockerhub-sync.yml` — the only workflow consumer
    (`peter-evans/dockerhub-description` requires Delete scope to PATCH repo
    metadata; `Read, Write`-only PAT returns `403`) — and by the manual
    recovery snippets in this runbook.

Binding:

1. `secrets.DOCKERHUB_TOKEN_RW` must never be consumed in `dockerhub-sync.yml`
    or the anonymous/read-only `verify-latest-release.yml` (the write-scoped
    token is release-only).
1. `secrets.DOCKERHUB_TOKEN_DELETE` must never be consumed in
    `release-on-bump.yml` or `verify-latest-release.yml`.
1. Manual recovery snippets performing a tag delete (`--request DELETE`
    or `-X DELETE`) must name `DOCKERHUB_TOKEN_DELETE` and must not name
    `DOCKERHUB_TOKEN_RW` (the `_RW` token returns `401`). The lint
    counts a fence as a Docker Hub delete when it performs a DELETE and
    either addresses `hub.docker.com` or names a `DOCKERHUB_TOKEN`
    variant.
1. No unsuffixed `DOCKERHUB_TOKEN` secret may exist; only `_RW` and
    `_DELETE` variants are authoritative.

Rotation: on suspected compromise only.

## Notify-body parity invariant<a name="notify-body-parity-invariant"></a>

Two other copies of this failure-cause list exist and must stay in
parity with this runbook's "Common Docker Hub failure modes" section:

- `release-on-bump.yml`'s notify-failure issue body carries it as a
    `## Common Docker Hub causes` subsection.
- `dockerhub-sync.yml`'s notify-failure issue body carries the same three
    bullets as a `Common causes:` list, phrased against
    `DOCKERHUB_TOKEN_DELETE` rather than `_RW` because that is the token
    its own job consumes. It adds a fourth, sync-specific bullet about a
    no-op parent `release-on-bump` run, which carries no parity obligation
    here.

Nothing enforces this parity, so an edit here has to reach both
workflows by hand.
