# Invariant index (fixture)

## Security

- **Workflow SHA pinning** — every `uses:` SHA-pinned. → [security/repo-config.md](security/repo-config.md) <!-- enforcer: scripts/check-uses-sha-pinned.sh; ci: lint-workflow-security; hook: uses-sha-pinned -->
- **Renovate invariants** — pinDigests, minimumReleaseAge. → [security/repo-config.md](security/repo-config.md) <!-- enforcer: scripts/check-renovate-invariants.sh; ci: renovate-invariants; hook: renovate-invariants -->
- **harden-runner** — first step in every job. → [security/trust-model.md](security/trust-model.md) <!-- enforcer: scripts/check-harden-runner-first.sh; ci: lint-workflow-security; hook: harden-runner-first -->
