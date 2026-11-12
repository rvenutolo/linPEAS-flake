# CI credentials runbook

Everything needed to recreate, from nothing, each credential the
workflows consume. Every credential lives in this repository's Actions
settings as a repository-level secret or variable; none is scoped to an
environment. What each one is allowed to do, and the blast radius of a
leak, is in the [Secrets section of
`SECURITY.md`](https://github.com/rvenutolo/linPEAS-flake/blob/main/SECURITY.md#secrets).

Personal access tokens follow one naming scheme on the provider side:
`linPEAS-flake/<SECRET>`, where `<SECRET>` is the repository secret that
holds the token. The name is what the provider's token list shows, so a
listed token maps to exactly one secret.

<!-- mdformat-toc start --slug=github --maxlevel=3 --minlevel=2 -->

- [Inventory](#inventory)
- [When to replace a credential](#when-to-replace-a-credential)
- [SCORECARD_TOKEN](#scorecard_token)
  - [Create](#create)
  - [Verify](#verify)
  - [Revoke the old token](#revoke-the-old-token)
- [Docker Hub: DOCKERHUB_USERNAME, DOCKERHUB_TOKEN_RW, DOCKERHUB_TOKEN_DELETE](#docker-hub-dockerhub_username-dockerhub_token_rw-dockerhub_token_delete)
  - [Create](#create-1)
  - [Verify](#verify-1)
  - [Revoke the old tokens](#revoke-the-old-tokens)
- [linpeas-flake-bumper GitHub App](#linpeas-flake-bumper-github-app)
  - [Register the App](#register-the-app)
  - [Install the App](#install-the-app)
  - [Store the credentials](#store-the-credentials)
  - [Verify](#verify-2)
  - [Replace only the private key](#replace-only-the-private-key)
  - [Remove the old App](#remove-the-old-app)

<!-- mdformat-toc end -->

## Inventory<a name="inventory"></a>

| Repository secret / variable      | Provider | Provider-side name                     | Consumed by                                                                                             |
| --------------------------------- | -------- | -------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `SCORECARD_TOKEN` (secret)        | GitHub   | `linPEAS-flake/SCORECARD_TOKEN`        | `scorecard-drift-check.yml`                                                                             |
| `DOCKERHUB_USERNAME` (secret)     | Docker   | the Docker Hub account name            | `release-on-bump.yml`, `dockerhub-sync.yml`                                                             |
| `DOCKERHUB_TOKEN_RW` (secret)     | Docker   | `linPEAS-flake/DOCKERHUB_TOKEN_RW`     | `release-on-bump.yml`                                                                                   |
| `DOCKERHUB_TOKEN_DELETE` (secret) | Docker   | `linPEAS-flake/DOCKERHUB_TOKEN_DELETE` | `dockerhub-sync.yml`, the manual snippets in [`dockerhub-recovery.md`](dockerhub-recovery.md)           |
| `BUMP_APP_PRIVATE_KEY` (secret)   | GitHub   | `linpeas-flake-bumper` App private key | `update-linpeas.yml`, `update-flake-lock.yml`, `renovate-flake-lock-refresh.yml`, `release-on-bump.yml` |
| `BUMP_APP_CLIENT_ID` (variable)   | GitHub   | `linpeas-flake-bumper` App client ID   | the same four workflows                                                                                 |

## When to replace a credential<a name="when-to-replace-a-credential"></a>

- On suspected compromise. Revoke the old credential **first**, then
    create and store the replacement: a leaked credential keeps its
    access for as long as it stays live. Workflow runs that need it fail
    on auth until the replacement is stored.
- When the provider revokes it, or a workflow starts failing auth with
    it (`401`, `403`, `Bad credentials`, `Resource not accessible by   personal access token`). Create and store the replacement, verify it,
    then delete the old entry if one is still listed.
- When the local copy is lost. Providers show a token or key once, so it
    can only be replaced. The old credential stays live until the
    replacement is verified; it is the rollback target until then.

Set every secret with `gh secret set <NAME> --repo rvenutolo/linPEAS-flake`
and paste the value at the prompt, so it never lands in shell history.

## SCORECARD_TOKEN<a name="scorecard_token"></a>

`scorecard-drift-check.yml` runs the OpenSSF Scorecard CLI against this
repository with the token in `GITHUB_AUTH_TOKEN`, on the scorecard step
only. The `Webhooks` check needs the `Webhooks` read permission, which
no `GITHUB_TOKEN` `permissions:` block can grant.

- **Type:** fine-grained personal access token.
- **Token name:** `linPEAS-flake/SCORECARD_TOKEN`.
- **Resource owner:** `rvenutolo`.
- **Repository access:** Only select repositories → `linPEAS-flake`.
- **Repository permissions, all Read-only:**
    - Contents — the checks that read repository files and releases
        (`Security-Policy`, `License`, `SBOM` and the rest of the curated
        set).
    - Metadata — mandatory; GitHub selects it for every fine-grained
        token.
    - Webhooks — the `Webhooks` check lists the repository's hooks.
- **Account permissions:** none.
- **Stored as:** repository secret `SCORECARD_TOKEN`.

### Create<a name="create"></a>

1. <https://github.com/settings/personal-access-tokens> → **Generate new
    token**.
1. Fill in the name, resource owner, repository access and permissions
    listed above.
1. **Generate token** and copy the `github_pat_…` value; GitHub shows it
    once.
1. `gh secret set SCORECARD_TOKEN --repo rvenutolo/linPEAS-flake`.

### Verify<a name="verify"></a>

```bash
gh workflow run scorecard-drift-check.yml --repo rvenutolo/linPEAS-flake
gh run watch --repo rvenutolo/linPEAS-flake
```

A green run, or a red one whose `scorecard-drift` issue lists real
findings, proves the token. `401`, `403` or `Resource not accessible by personal access token` in the log means the permissions above are not
what the token carries.

### Revoke the old token<a name="revoke-the-old-token"></a>

<https://github.com/settings/personal-access-tokens> → the old entry →
**Delete**. Only the token named `linPEAS-flake/SCORECARD_TOKEN` that
the verify run used stays.

## Docker Hub: DOCKERHUB_USERNAME, DOCKERHUB_TOKEN_RW, DOCKERHUB_TOKEN_DELETE<a name="docker-hub-dockerhub_username-dockerhub_token_rw-dockerhub_token_delete"></a>

Two personal access tokens for the Docker Hub account that owns
`rvenutolo/linpeas`, split so the release push never holds delete
rights. Docker Hub offers no repository selection for a personal access
token: each one reaches every repository on the account, so the
permission split is the only narrowing. The binding rules for which workflow may consume which token are
in [DOCKERHUB_TOKEN split](dockerhub-recovery.md#dockerhub_token-split-rw--delete).

- **`DOCKERHUB_USERNAME`** — the Docker Hub account name. It must equal
    the owner segment of `rvenutolo/linpeas`.
- **`DOCKERHUB_TOKEN_RW`**
    - **Type:** Docker Hub personal access token.
    - **Token description:** `linPEAS-flake/DOCKERHUB_TOKEN_RW`.
    - **Access permissions:** Read & Write — `release-on-bump.yml` pushes
        the per-arch images and the multi-arch manifest. No Delete, so a
        leak cannot remove tags.
    - **Stored as:** repository secret `DOCKERHUB_TOKEN_RW`.
- **`DOCKERHUB_TOKEN_DELETE`**
    - **Type:** Docker Hub personal access token.
    - **Token description:** `linPEAS-flake/DOCKERHUB_TOKEN_DELETE`.
    - **Access permissions:** Read, Write & Delete —
        `peter-evans/dockerhub-description` in `dockerhub-sync.yml` PATCHes
        the repository's metadata, which a Read & Write token gets `403`
        on, and the recovery runbook deletes orphan tags with it.
    - **Stored as:** repository secret `DOCKERHUB_TOKEN_DELETE`.

### Create<a name="create-1"></a>

For each token:

1. <https://app.docker.com/settings/personal-access-tokens> → **Generate
    new token**.
1. Fill in the description and access permissions listed above.
1. **Generate** and copy the `dckr_pat_…` value; Docker Hub shows it
    once.
1. `gh secret set DOCKERHUB_TOKEN_RW --repo rvenutolo/linPEAS-flake`, or
    `DOCKERHUB_TOKEN_DELETE`, to match the token.

`DOCKERHUB_USERNAME` changes only with the account:
`gh secret set DOCKERHUB_USERNAME --repo rvenutolo/linPEAS-flake`.

### Verify<a name="verify-1"></a>

`DOCKERHUB_TOKEN_DELETE` is proven by a green `dockerhub-sync` run, which
needs its Delete permission:

```bash
gh workflow run dockerhub-sync.yml --repo rvenutolo/linPEAS-flake
gh run watch --repo rvenutolo/linPEAS-flake
```

`DOCKERHUB_TOKEN_RW` is consumed only by a release, so check it before
storing it with a login exchange, which proves the token authenticates
but not its permissions:

```bash
read -r -s -p 'DOCKERHUB_TOKEN_RW: ' DOCKERHUB_TOKEN_RW && echo
jq -n --arg u rvenutolo --arg p "${DOCKERHUB_TOKEN_RW}" \
  '{username: $u, password: $p}' \
  | curl --fail --silent --show-error --output /dev/null \
    --header 'Content-Type: application/json' --data @- \
    https://hub.docker.com/v2/users/login \
  && echo 'login OK'
unset DOCKERHUB_TOKEN_RW
```

The next `release-on-bump` run that publishes images proves the Write
permission.

### Revoke the old tokens<a name="revoke-the-old-tokens"></a>

<https://app.docker.com/settings/personal-access-tokens> → select the old
entry → **Delete**. Each secret then maps to the one token whose
description names it.

## linpeas-flake-bumper GitHub App<a name="linpeas-flake-bumper-github-app"></a>

The bump, refresh and changelog workflows act as this App. They mint a
one-hour installation token per job with
`actions/create-github-app-token`, and commit through REST
`PUT /contents`, which GitHub web-flow-signs only for an App
installation token. The credential model, and which jobs may hold the
key, is in [App-based bump
auth](../security/repo-config.md#app-based-bump-auth).

Keep the name `linpeas-flake-bumper`. The workflows read the slug at
run time from the token step's `app-slug` output, so code works under
any name, but the docs name the App and the bump PRs' author by it.

### Register the App<a name="register-the-app"></a>

<https://github.com/settings/apps> → **New GitHub App**:

- **GitHub App name:** `linpeas-flake-bumper`.
- **Homepage URL:** `https://github.com/rvenutolo/linPEAS-flake`.
- **Callback URL:** none. **Request user authorization (OAuth) during
    installation:** off. **Enable Device Flow:** off. The App never acts
    for a user.
- **Setup URL:** none.
- **Webhook → Active:** off. The workflows call the App; it receives no
    events.
- **Repository permissions:**
    - Contents: Read and write — commits bump files through
        `PUT /contents` and creates the bump branch.
    - Pull requests: Read and write — opens, comments on, closes and
        auto-merges bump and changelog PRs.
    - Metadata: Read-only — mandatory; GitHub selects it.
    - Everything else: No access. In particular no `Workflows`
        permission, so the App cannot change `.github/workflows/`.
- **Organization and account permissions:** none.
- **Subscribe to events:** none.
- **Where can this GitHub App be installed?:** Only on this account.

**Create GitHub App**, then on the App's settings page:

1. Copy the **Client ID** (`Iv…`). `actions/create-github-app-token`
    takes the Client ID, not the numeric App ID.
1. **Private keys → Generate a private key.** The browser downloads a
    `.pem` file; GitHub keeps only its fingerprint.

### Install the App<a name="install-the-app"></a>

App settings → **Install App** → `rvenutolo` → **Only select
repositories** → `linPEAS-flake` → **Install**.

### Store the credentials<a name="store-the-credentials"></a>

```bash
gh variable set BUMP_APP_CLIENT_ID --repo rvenutolo/linPEAS-flake --body '<Client ID>'
gh secret set BUMP_APP_PRIVATE_KEY --repo rvenutolo/linPEAS-flake < path/to/linpeas-flake-bumper.pem
```

Then delete the local `.pem` file; the secret is the only copy needed.

### Verify<a name="verify-2"></a>

A job mints the App token only when it has something to commit, so the
proof is the next bump: a `chore: bump linpeas` or flake-lock PR opened
by `app/linpeas-flake-bumper` and merged. A dispatch of
`update-linpeas.yml` or `update-flake-lock.yml` exercises it at once
when there is a pending bump. A failure surfaces as the workflow's
notify issue, and `stale-pin-check.yml` names a broken key or
uninstalled App as a cause.

### Replace only the private key<a name="replace-only-the-private-key"></a>

The App and its installation stay; only the key changes. App settings →
**Private keys → Generate a private key**, store it as above, verify,
then **Delete** the old key's entry by its fingerprint. Under suspected
compromise delete the old key first.

### Remove the old App<a name="remove-the-old-app"></a>

When the whole App is being replaced, the old one holds the
`linpeas-flake-bumper` name, so it goes first: <https://github.com/settings/apps>
→ the App → **Advanced → Delete GitHub App**, then register the
replacement above. Bump runs fail on auth until the replacement's
credentials are stored.
