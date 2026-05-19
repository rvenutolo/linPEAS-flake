# Repository configuration

Overview of the GitHub-side configuration enforced on
`rvenutolo/linPEAS-flake`. Authoritative details live in the linked
sub-docs.

## Allowed-actions allowlist

`actions.permissions.allowed_actions` is `selected`. Only `uses:`
references drawn from a vetted vendor allowlist may run in this repo.

See [`allowed-actions.md`](allowed-actions.md) for the canonical
vendor list and the procedure for adding a new vendor.

## App-based bump auth

Bump workflows authenticate as the `linpeas-flake-bumper` GitHub App,
not as a personal access token.

- **Client ID:** `vars.BUMP_APP_CLIENT_ID` (public).
- **Private key:** `secrets.BUMP_APP_PRIVATE_KEY` (PEM).
- **Installation:** scoped to this repository only.
- **Permissions:** `Contents: Read and write`, `Pull requests: Read and
  write`. No `Workflows` permission.
- **Token lifetime:** one hour; minted per job by
  `actions/create-github-app-token` and automatically revoked at job end.

Tokens flow only through `${{ steps.app-token.outputs.token }}` →
`GH_TOKEN` → `gh api` / `gh pr`. No `git push` uses them. Commits land
via REST `PUT /repos/{owner}/{repo}/contents/{path}` → web-flow-signed
by GitHub. The key never enters compute jobs that run untrusted
third-party actions; see `update-linpeas.yml` and `update-flake-lock.yml`
for the credential split.

## Branch protection

`main` is protected by the `protect-main` ruleset. See
[`required-checks.md`](required-checks.md) for the gating check list and
[`settings-posture.md`](settings-posture.md) for the full ruleset shape.

## Merge policy

Merge-commit only. Enforced at both layers:

- **Repo:** `allow_merge_commit=true`, `allow_rebase_merge=false`,
  `allow_squash_merge=false`.
- **Ruleset:** `pull_request.allowed_merge_methods=["merge"]`.

Why: see [`../development/git.md`](../development/git.md#merge-policy).

## Required checks

The `protect-main` ruleset requires a specific set of CI checks before
merge. The authoritative list lives in
[`required-checks.md`](required-checks.md), which mirrors the live
ruleset.

## Signed commits

`required_signatures` is enforced on the `protect-main` ruleset. Every
commit on `main` must carry a valid signature.

See [`../development/git.md`](../development/git.md#commit-signing) for
how branch commits and bot commits both satisfy this.

## Tag protection

The `release-tag-protection` ruleset blocks deletion, non-fast-forward
update, and arbitrary update of release-tag refs matching
`refs/tags/[0-9]{8}-[0-9a-f]{7,40}`.

Drift is asserted by the `tag-protection-drift-check` CI job and the
matching pre-commit hook.
