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
lycheeverse/*
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
        "lycheeverse/*",
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

There is no live-drift CI check for this setting. If you suspect drift:

```bash
gh api /repos/rvenutolo/linPEAS-flake/actions/permissions/selected-actions
```

Compare against the canonical list above. Drift = security incident.
