# Tests

Bash test harnesses for the script-based invariant checks under
`scripts/`. Each test exercises its target script against a tree of
fixtures with expected exit codes and stderr substrings.

Most tests run via `just verify` (also runs the underlying scripts
against the live tree); it reaches the majority of `tests/*.test.sh`
harnesses but not all of them.

## Layout

```text
tests/
├── <script-name>.test.sh         # one harness per script
├── fixtures/
│   ├── <script-name>/
│   │   ├── good.yml              # minimal passing fixture
│   │   ├── good-*.yml            # additional passing variants
│   │   ├── bad-<failure-mode>.yml
│   │   └── ...
```

Current harness / fixture pairs:

| Script                                      | Harness                                        | Fixtures                                  |
| ------------------------------------------- | ---------------------------------------------- | ----------------------------------------- |
| `scripts/check-uses-sha-pinned.sh`          | `tests/check-uses-sha-pinned.test.sh`          | `tests/fixtures/uses-sha-pinned/`         |
| `scripts/check-pr-workflows-no-secrets.sh`  | `tests/check-pr-workflows-no-secrets.test.sh`  | `tests/fixtures/pr-workflows-no-secrets/` |
| `scripts/check-required-checks-no-paths.sh` | `tests/check-required-checks-no-paths.test.sh` | `tests/fixtures/required-checks/`         |
| `scripts/check-tag-protection.sh`           | `tests/check-tag-protection.test.sh`           | `tests/fixtures/tag-protection/`          |
| `scripts/check-renovate-invariants.sh`      | `tests/check-renovate-invariants.test.sh`      | `tests/fixtures/renovate-invariants/`     |
| `scripts/gen-dashboard-data.sh`             | `tests/gen-dashboard-data.test.sh`             | `tests/fixtures/dashboard-data/`          |

## Harness conventions

Every harness opens with:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/<script-name>.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/<script-name>"
```

Then defines a single `expect` function that takes
`<fixture> <want_exit> <want_stderr_substring>`, runs the script
with environment overrides pointing it at the fixture, and asserts
on exit code + stderr.

A scenario's expected substring must not appear in any sibling
scenario's output. A substring the nominal path also prints matches
whether or not the asserted behavior exists, so the assertion proves
nothing. Harnesses source `scripts/lib/harness-assert.sh`, call
`harness_assert_record <scenario> <substring> <output-file>...` after
each script invocation, and end `main` with
`harness_assert_verify || failures=$((failures + 1))`. The gate fails
the harness on any substring that does not discriminate.

Environment-variable overrides scoped to test invocation:

| Variable                         | Script                                                                                                    | Purpose                           |
| -------------------------------- | --------------------------------------------------------------------------------------------------------- | --------------------------------- |
| `WORKFLOWS_DIR_OVERRIDE`         | `check-uses-sha-pinned.sh`                                                                                | swap the workflows scan root      |
| `WORKFLOW_FILE_FILTER`           | `check-uses-sha-pinned.sh`                                                                                | restrict to a single fixture file |
| `RENOVATE_JSON_OVERRIDE`         | `check-renovate-invariants.sh`, `check-renovate-markers-matched.sh`, `check-renovate-config-validator.sh` | swap the renovate.json path       |
| `SCAN_ROOT`                      | `check-renovate-markers-matched.sh`                                                                       | swap the scanned tree root        |
| `TAG_PROTECTION_FIXTURE`         | `check-tag-protection.sh`                                                                                 | swap the rulesets JSON path       |
| `PIN_FILE_OVERRIDE`              | `gen-dashboard-data.sh`                                                                                   | swap the linpeas-pin.json path    |
| `UPSTREAM_RELEASE_JSON_OVERRIDE` | `gen-dashboard-data.sh`                                                                                   | swap upstream release JSON        |
| `LATEST_RELEASE_JSON_OVERRIDE`   | `gen-dashboard-data.sh`                                                                                   | swap rvenutolo release JSON       |

Each script defines its own overrides — check the script for the
canonical list before writing a new test.

## Adding a fixture

1. Pick the script you are testing. Create
    `tests/fixtures/<script-name>/` if it does not exist.

1. Add a fixture file. Name with the convention:

    - `good.yml` (or `good-<scenario>.yml`) — script must exit 0.
    - `bad-<failure-mode>.yml` — script must exit non-zero with a
        specific stderr substring.

1. Add an `expect` line to the harness, for example:

    ```bash
    expect bad-new-mode.yml 1 "stderr substring identifying the failure"
    ```

1. Record the scenario with the discrimination gate, if the harness's
    scenario runner does not already do it for every `expect` line:

    ```bash
    harness_assert_record 'bad-new-mode' "${expected_stderr}" "${stderr_file}"
    ```

1. Run `bash tests/<script-name>.test.sh` locally to verify. A
    `does not discriminate` line means the chosen substring also
    appears in another scenario's output — pick a token unique to the
    failure path (typically the level tag plus the label rather than
    the bare label) and re-run.

1. Make sure `_typos.toml` still excludes `tests/fixtures/**` —
    fixture content is often intentionally malformed.

## Adding a new test harness

1. Write the script's invariant first; commit it.
1. Create `tests/<script-name>.test.sh` mirroring the existing
    harnesses' shape (env-var overrides, `expect` function).
1. Create `tests/fixtures/<script-name>/` with at least one `good`
    and one `bad-*` fixture.
1. Wire the harness to the discrimination gate: source
    `scripts/lib/harness-assert.sh`, call `harness_assert_record` for
    every scenario, and call `harness_assert_verify` at the end of
    `main`. A harness that asserts produced artifact content — a
    rewritten workflow file, a generated doc — rather than captured
    scenario output belongs on the `EXEMPT` array in
    `tests/_harness_assert_wired.test.sh` with a rationale comment
    instead.
1. Register the harness so it actually runs: add its basename to
    `.github/lint-groups.yml` if the `check-<name>.sh` + `test.sh`
    pair belongs to a lint group, add it to the `HARNESSES` array in
    `scripts/run-harness-group.sh` if it is a standalone harness, or
    name it `tests/refresh-*.test.sh` to be picked up automatically
    by `scripts/run-doc-freshness.sh`'s glob.
1. If the script is wired into a CI required check, also document
    it in `docs/security/required-checks.md` and ensure
    `scripts/check-required-checks-no-paths.sh` covers the new
    workflow file.
