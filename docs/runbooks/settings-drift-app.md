# `settings-drift-checker` GitHub App runbook

The `settings-posture-drift-check` workflow (and any other drift-check that needs admin-scoped read access to repo settings) authenticates as a dedicated read-only GitHub App. This isolates the admin-read blast radius from both `secrets.GITHUB_TOKEN` (which never receives admin scope) and from the `linpeas-flake-bumper` App used for bump commits.

<!-- mdformat-toc start --slug=github --maxlevel=3 --minlevel=2 -->

- [Why a separate App](#why-a-separate-app)
- [One-time setup](#one-time-setup)
- [Failure modes](#failure-modes)
- [Rotation](#rotation)
- [Reuse for related drift checks](#reuse-for-related-drift-checks)

<!-- mdformat-toc end -->

## Why a separate App<a name="why-a-separate-app"></a>

- **`secrets.GITHUB_TOKEN`** — never granted admin scope by GitHub regardless of `permissions:` block declarations. Returns `HTTP 403 Resource not accessible by integration` on `/repos/X/actions/permissions`, `security_and_analysis` fields of `/repos/X`, and environment endpoints.
- **`linpeas-flake-bumper`** — the bump-bot App. Adding admin scope to it widens the blast radius of its write-capable installation token. Keep it scoped to its bump duties.
- **`settings-drift-checker`** — this App. **Read-only**. Administration:Read + Metadata:Read. Cannot mutate any state. If its private key leaks, the worst an attacker gains is a snapshot of already-public repo metadata plus the admin-only fields a repo admin can already read in the repo Settings UI.

## One-time setup<a name="one-time-setup"></a>

1. **Create the App.** <https://github.com/settings/apps/new> (or the user-account Apps page if registering personally).

    - **GitHub App name**: `settings-drift-checker` (or any unique name).

    - **Homepage URL**: `https://github.com/rvenutolo/linPEAS-flake`

    - **Webhook**: deactivate (no events needed).

    - **Repository permissions**:

        - **Administration**: Read-only
        - **Metadata**: Read-only

    - **Subscribe to events**: none.

    - **Where can this GitHub App be installed?**: Only on this account.

1. **Note the Client ID** (shown on the App's "About" page after creation).

1. **Generate a private key**. App page → "Private keys" → "Generate a private key". A `.pem` file downloads.

1. **Install the App on this repo**. App page → "Install App" → choose your account → "Only select repositories" → `rvenutolo/linPEAS-flake`.

1. **Add the Client ID as a repository variable**:

    ```bash
    gh variable set SETTINGS_DRIFT_APP_CLIENT_ID --body '<client-id>' --repo rvenutolo/linPEAS-flake
    ```

1. **Add the private key as a repository secret**:

    ```bash
    gh secret set SETTINGS_DRIFT_APP_PRIVATE_KEY --body "$(cat path/to/downloaded-key.pem)" --repo rvenutolo/linPEAS-flake
    ```

    Then delete the local `.pem` file — the only copy now lives in GitHub Secrets.

1. **Manually dispatch the workflow once** to confirm setup:

    ```bash
    gh workflow run settings-posture-drift-check.yml --repo rvenutolo/linPEAS-flake
    gh run watch --repo rvenutolo/linPEAS-flake
    ```

    Expect the `drift-check` job to pass with `settings-posture: live repo configuration matches docs/security/settings-posture.md` in the log.

## Failure modes<a name="failure-modes"></a>

- **`Error: Could not create installation access token`** — App not installed on this repo, or `SETTINGS_DRIFT_APP_CLIENT_ID` / `SETTINGS_DRIFT_APP_PRIVATE_KEY` mismatched or rotated without updating both halves.
- **`HTTP 403 Resource not accessible by integration` on a settings endpoint** — App permissions narrower than required. Open the App's "Permissions & events" page and confirm Administration:Read + Metadata:Read are present. After widening, GitHub requires installation owners to accept the new permission scope before it takes effect.
- **Workflow fires but `drift-check` reports drift on settings nobody touched** — most often: GitHub added a new field to one of the endpoints with a default that differs from the doc's expectation. Treat as a security review: either the new default is acceptable (update the doc) or it's a posture regression (revert via API or UI).

## Rotation<a name="rotation"></a>

Rotate the private key every time:

- the previous key may have been exposed (e.g., committed accidentally, shared in a screenshot, copied to a non-secret store)
- a maintainer with key access leaves
- the App's permissions are widened

To rotate:

1. App page → "Private keys" → "Generate a private key" (creates a new key, does not invalidate the old one).

1. Update the repo secret:

    ```bash
    gh secret set SETTINGS_DRIFT_APP_PRIVATE_KEY --body "$(cat new-key.pem)" --repo rvenutolo/linPEAS-flake
    ```

1. Re-dispatch the workflow and confirm the `drift-check` job passes.

1. App page → delete the old key. Only after the run above is green: a
    truncated or wrong `.pem` in step 2 fails exactly as a missing key
    does, and the old key is the only thing left to roll back to.

## Reuse for related drift checks<a name="reuse-for-related-drift-checks"></a>

This App is intentionally read-only and broadly useful. Any future workflow that needs Administration:Read + Metadata:Read against this repo should reuse `vars.SETTINGS_DRIFT_APP_CLIENT_ID` + `secrets.SETTINGS_DRIFT_APP_PRIVATE_KEY` rather than creating a parallel App. Subsequent drift checks (e.g., `allowed-actions-api-drift-check`) follow the same auth pattern.

If a future drift check requires permissions the App does not yet have, widen the App rather than splitting into another App — every App's private key is itself a secret with rotation cost. The trade-off: one App means one private-key blast radius.
