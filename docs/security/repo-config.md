# Repository configuration

Overview of the GitHub-side configuration enforced on
`rvenutolo/linPEAS-flake`. Authoritative details live in the linked
sub-docs.

## Allowed-actions allowlist

`actions.permissions.allowed_actions` is `selected`. Only `uses:`
references drawn from a vetted vendor allowlist may run in this repo.

See [`allowed-actions.md`](allowed-actions.md) for the canonical
vendor list and the procedure for adding a new vendor.

## Workflow action SHA pinning

Every `uses:` in `.github/workflows/*.yml` and `.github/actions/**/*.yml`
must end with a full 40-hex SHA + trailing `# vX.Y.Z` comment, OR be
a path-relative `./...` self-reference. Includes first-party GitHub-owned
actions.

Enforced by `scripts/check-uses-sha-pinned.sh` (member check
`uses-sha-pinned` of the `lint-workflow-security` CI job; pre-commit hook same name with `NIX_BUILD_TOP` guard).
Belt-and-braces backup to the GitHub-side `sha_pinning_required` setting.

## App-based bump auth

Bump workflows authenticate as the `linpeas-flake-bumper` GitHub App,
not as a personal access token.

- **Client ID:** `vars.BUMP_APP_CLIENT_ID` (public).
- **Private key:** `secrets.BUMP_APP_PRIVATE_KEY` (PEM).
- **Installation:** scoped to this repository only.
- **Permissions:** `Contents: Read and write`, `Pull requests: Read and write`. No `Workflows` permission.
- **Token lifetime:** one hour; minted per job by
    `actions/create-github-app-token` and automatically revoked at job end.

{% raw %}
Tokens flow only through `${{ steps.app-token.outputs.token }}` →
`GH_TOKEN` → `gh api` / `gh pr`. No `git push` uses them. Commits land
via REST `PUT /repos/{owner}/{repo}/contents/{path}` → web-flow-signed
by GitHub.
{% endraw %} The key never enters compute jobs that run untrusted
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

Drift is asserted by the `tag-protection-drift-check` CI job.

Ruleset `release-tag-protection` (target=tag, enforcement=active,
rules=[deletion, update, non_fast_forward], bypass_actors empty,
include=`refs/tags/[0-9]{8}-[0-9a-f]{7,40}`; fallback `refs/tags/**` if
regex ever rejected).

Lint: `scripts/check-tag-protection.sh` via `tag-protection-drift-check`
required CI job. GitHub rulesets API shape change → update script +
fixtures together.

## Renovate invariants

`scripts/check-renovate-invariants.sh` asserts:

1. `extends` includes `"helpers:pinGitHubActionDigests"`.
1. `minimumReleaseAge` is a non-empty string (e.g. `"7 days"`).
1. No top-level `automerge` key — must live exclusively in per-manager
    `packageRules`.
1. The `github-actions` `packageRule` sets `pinDigests: true`.

Enforced by `renovate-invariants` required CI job.

`scripts/check-renovate-markers-matched.sh` enforces a complementary
file-level rule: every file in the tree that carries a `# renovate: datasource=…` marker must be consumed by a live customManager — a
`managerFilePattern` must scope the marker's file and a `matchString`
must match a line in it. The rule is file-level, which covers both
inline markers (value and comment on the same line) and above-style
markers (comment on its own line, matched value on the next) without a
line-adjacency heuristic. A customManager that matches none of its
declarations silently freezes the dependency outside automation
coverage; this check fails CI before that can happen. Wired into the
`renovate-invariants` CI job.

## Pin digest provenance

`scripts/check-pin-digest-provenance.sh` (in the `lint-doc-invariants`
CI group) diffs every action pin (`uses: <path>@<sha> # <version>`)
and the octoscan `OCTOSCAN_DIGEST`/`OCTOSCAN_VERSION` pair against
`origin/main`:

1. A SHA/digest that moves while its version label stays the same is
    a repointed released tag — the digest-repoint supply-chain class
    (a force-pushed upstream tag reaches a Renovate digest-only bump
    that `minimumReleaseAge` cannot delay, because the version's
    release timestamp is unchanged). Hard fail; auto-merge is blocked.
    Remediation: verify the upstream release notes explain the
    re-tag; if legitimate, either push a commit to the bot branch that
    moves the version label together with the SHA (converting the pin
    to a version-label bump, which the gate passes) or update the pin
    to the corrected upstream release. A digest-only change is never
    merged unreviewed.
1. A floating-major pin (`# vN`, no immutable patch tag upstream)
    legitimately retargets across patches, so its digest moves are
    instead verified reachable from the upstream default branch via
    the GitHub compare API — a dangling force-pushed commit fails.
    API errors fail the job loudly (exit 2), never silently.
1. Version-label bumps (SHA and comment move together) pass here;
    they are quarantined by `minimumReleaseAge` and re-checked daily
    by `ratchet-pin-audit`.
1. A self-reference pin — a `uses:` whose owner/repo is this repo's
    own — is exempt from this gate entirely: it has no upstream
    release tag to repoint against, since Renovate's pinDigests rule
    tracks this repo's own main HEAD rather than an upstream tag.
