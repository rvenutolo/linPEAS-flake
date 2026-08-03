# Invariant index (fixture)

## Security

- **No enforcers** — every field is the explicit `-` sentinel, so the fixture ci.yml job below is an orphan unless the ci-job EXEMPT list covers it. → [security/repo-config.md](security/repo-config.md) <!-- enforcer: -; ci: -; hook: - -->
