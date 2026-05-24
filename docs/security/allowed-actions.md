# Allowed Actions Vendor Allowlist — `rvenutolo/linPEAS-flake`

`actions.permissions.allowed_actions` is set to `selected`. Each entry below is a vendor pattern from which `uses:` references may be drawn. Adding a new vendor is a **deliberate** action: see "Adding a vendor" below.

## Allowlist (canonical)

```text
actions/*
anchore/*
aquasecurity/*
cachix/*
crate-ci/*
DavidAnson/*
DeterminateSystems/*
editorconfig-checker/*
github/*
gitleaks/*
google/*
lycheeverse/*
pascalgn/*
peter-evans/*
rvenutolo/*
step-security/*
wagoid/*
```

## Why this exists

`allowed_actions: all` permits any action from any vendor — a hostile or accidental edit could introduce `attacker/exfil-action@SHA` and the only thing keeping it out is human review (which this solo-maintainer repo does not require on PRs). The allowlist makes vendor introduction explicit.

## Adding a vendor

1. Edit this doc — append the new pattern.

1. Edit the live setting:

    ```bash
    gh api -X PUT /repos/rvenutolo/linPEAS-flake/actions/permissions/selected-actions --input - <<'JSON'
    {
      "github_owned_allowed": true,
      "verified_allowed": false,
      "patterns_allowed": [
        "actions/*",
        "anchore/*",
        "aquasecurity/*",
        "cachix/*",
        "crate-ci/*",
        "DavidAnson/*",
        "DeterminateSystems/*",
        "editorconfig-checker/*",
        "github/*",
        "gitleaks/*",
        "google/*",
        "lycheeverse/*",
        "pascalgn/*",
        "peter-evans/*",
        "rvenutolo/*",
        "step-security/*",
        "wagoid/*",
        "NEW_VENDOR/*"
      ]
    }
    JSON
    ```

1. Commit the doc change in the same PR that introduces the new `uses:` reference.

`github_owned_allowed: true` permits `actions/*` and `github/*` implicitly — but listing them explicitly here is defensive against future GitHub-side semantic drift.

`verified_allowed: false` is intentional. The "Verified Creator" allowlist is opaque and grows without our involvement; we prefer named vendors.

## Drift detection

The canonical list above is enforced against live API state by `scripts/check-allowed-actions-api.sh`, run on a daily cron + `workflow_dispatch` from `.github/workflows/allowed-actions-api-drift-check.yml`. On mismatch the workflow opens a deduped `allowed-actions-drift` issue, which auto-closes when the next run sees the allowlist reconciled.

The check covers three things:

- every entry in the doc must appear in `patterns_allowed` (and vice versa)
- `github_owned_allowed` must be `true`
- `verified_allowed` must be `false`

The `/actions/permissions/selected-actions` endpoint requires Administration:Read scope, which `secrets.GITHUB_TOKEN` cannot have. The workflow authenticates via the read-only `settings-drift-checker` GitHub App documented at [`docs/runbooks/settings-drift-app.md`](../runbooks/settings-drift-app.md).

To probe manually from a developer shell (requires `gh auth login` with admin-read scope on the repo):

```bash
nix develop --command ./scripts/check-allowed-actions-api.sh
```

Exits 0 on full match, 1 on any drift, with every mismatched entry logged to stderr.
