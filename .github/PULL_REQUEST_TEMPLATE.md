## Summary

<!-- 1-3 bullets describing what changed and why. The PR title becomes
the merge-commit subject (must satisfy Conventional Commits); the body
below becomes the merge-commit body. -->

## Test plan

<!-- Bulleted checklist of what was verified locally / will verify in CI. -->

- [ ] `just verify` passes locally
- [ ] `just check` (`nix flake check`) passes locally
- [ ] If touching workflows: `nix develop --command zizmor --min-severity=low .github/workflows/<file>.yml`
- [ ] If touching `flake.nix` inputs: ran `nix flake update <name>` and committed the refreshed `flake.lock` plus the regenerated lock-derived docs (see `docs/architecture/flake-input-bumps.md`, step 4)

## Checklist

- [ ] PR title satisfies Conventional Commits (`lint-pr-title` will enforce)
- [ ] Every branch commit independently satisfies Conventional Commits (`commitlint` will enforce)
- [ ] All branch commits are signed (`required_signatures` is enforced on `main`)
- [ ] If touching a security invariant, the corresponding entry in `docs/invariant-index.md` is updated in the same change
- [ ] If adding a new external `uses:` action, the vendor is on the `allowed_actions` allowlist (`docs/security/allowed-actions.md`)
