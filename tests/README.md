# Tests

Bash test harnesses for the invariant checks under `scripts/` and the
shared libraries under `scripts/lib/`. Most exercise a target script
against a committed fixture tree with expected exit codes and stderr
substrings; the rest build their tree at runtime or target a library, a
file set, or another harness.

`just verify` runs most `tests/*.test.sh` harnesses — not all — and
also runs the underlying scripts against the live tree.

## Layout

```text
tests/
├── <script-name>.test.sh         # one harness per script
├── fixtures/
│   ├── <fixture-dir>/            # named after the harness, or after the
│   │   │                         # harness with its `check-` prefix
│   │   │                         # stripped — the harness's own FIXTURES
│   │   │                         # constant is canonical
│   │   ├── good.<ext>            # minimal passing fixture
│   │   ├── good-*.<ext>          # additional passing variants
│   │   ├── bad-<failure-mode>.<ext>
│   │   └── ...
```

The `good` / `bad-` prefix is the portable part; the extension follows
whatever the subject lint reads. Workflow-scanning lints use `.yml`, but
fixtures across this tree are also `.yaml`, `.sh`, `.json`, `.md`,
`.lock`, `.toml`, `.nix`, `.awk`, `.txt`, `.tsv`, and extensionless
command shims.

Neither shape is guaranteed: a handful of directories are named for the
invariant rather than for the harness, so read the harness's `FIXTURES`
constant rather than inferring a path from its name. Roughly a third of
the harnesses build their tree at runtime and have no fixture directory
at all; those render an em dash in the census.

Every harness, its subject and its fixture directories are listed in
[`docs/reference/test-harnesses.md`](../docs/reference/test-harnesses.md),
which `scripts/refresh-test-harnesses.sh` generates and a pre-commit
hook holds fresh.

## Harness conventions

Every harness opens with a shebang, `set -Eeuo pipefail`, `IFS=$'\n\t'`,
and a readonly `REPO_ROOT` derived from `git rev-parse --show-toplevel`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
```

The `REPO_ROOT` assignment is spelled two ways across the tree and both
are accepted — the direct form above, and a two-step form that assigns a
lowercase temp first. Match whichever the file you are editing already
uses rather than converting it:

```bash
repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
```

The opener is enforced, not just documented:
`scripts/check-harness-preamble.sh` (member check `harness-preamble` in
the `lint-script-hygiene` CI group) fails any harness missing the
shebang, the `set` line, the strict IFS line, or a readonly `REPO_ROOT`
derived from `git rev-parse --show-toplevel`, and accepts both
spellings above.

A harness with a single script subject then binds it, and one that reads
a committed fixture tree binds that:

```bash
readonly SCRIPT="${REPO_ROOT}/scripts/<script-name>.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/<script-name>"
```

Neither of those two is universal. A harness that exercises a library or
a cross-cutting rule rather than one script assigns no `SCRIPT`, and
declares its subject with a `# @subject` header annotation instead.
Exactly one of `SCRIPT=` and `# @subject` is required and never both — the census
generator hard-fails a harness that declares no subject or declares one
twice, and `doc-freshness` runs it. A harness that builds its tree at
runtime assigns no `FIXTURES`; one that reaches a committed tree only
through an environment override declares it with
`# @fixtures tests/fixtures/<name>`, so that tree is not reported as an
orphan.

Most check harnesses then define a single scenario runner: either an
`expect` function taking `<fixture> <want_exit> <want_stderr_substring>`,
or a `run_scenario` function adding a leading scenario name to the same
contract. Both run the script with environment overrides pointing it at
the fixture and assert on exit code + stderr. The rest use per-scenario
helpers (`expect_empty_scan`, `expect_failure`, `run_expect`) or a bare
`pass`/`fail` counter — the shebang, `set`, `IFS` and readonly
`REPO_ROOT` above are universal, but this assertion shape is a
convention rather than a requirement.

A scenario's expected substring must not appear in any sibling
scenario's output. A substring the nominal path also prints matches
whether or not the asserted behavior exists, so the assertion proves
nothing. Harnesses source `scripts/lib/harness-assert.sh`, call
`harness_assert_record <scenario> <substring> <output-file>...` after
each script invocation, and end `main` with
`harness_assert_verify || failures=$((failures + 1))`. The gate fails
the harness on any substring that does not discriminate.

The gate's *wiring verdict* reaches a harness only if it asserts with a
quiet `grep`, which is how `scripts/check-harness-assert-wired.sh` tells
an assertion from a data extraction. A harness that asserts another way —
a `[[ ${out} != *"${want}"* ]]` test, say — is outside that verdict, so
it needs neither the wiring nor an `EXEMPT` entry. Both exemption
ratchets still cover it: it may not register `harness_assert_exempt`, and
a `harness_assert_parity_exempt` from it still needs a
`PARITY_EXEMPT_ALLOWED` entry.

The same gate also enforces parity: two scenarios in one harness must
not produce byte-identical whole outcomes (exit code + stdout +
stderr), because a scenario indistinguishable from a sibling proves
nothing the sibling did not already prove. The first remedies are to
make the outputs differ, or to fold the two into one record with
`harness_assert_also <substring>` (which attaches another asserted
substring to the preceding record). The last-resort relief valve is
`harness_assert_parity_exempt <scenario> <other> <rationale>`, and only
harnesses named on the `PARITY_EXEMPT_ALLOWED` array in
`scripts/check-harness-assert-wired.sh` may register one — reaching for
it means widening that allowlist in the same change, which is the
review moment it deserves.

A harness that enumerates the filesystem is held to the same
scan-breadth rules as a repo script: `find` / `git ls-files` /
`git ls-tree` runs go through `enumerate_into`, glob-driven scans
through `glob_into`, and filter narrowing through `filter_into` (all in `scripts/lib/enumerate.sh`) — or carry an inline
`# enumerate-exempt: <rationale>`, `# glob-exempt: <rationale>` or
`# filter-exempt: <rationale>` marker. The scan set is `scripts/*.sh` plus
`tests/*.test.sh`, less `tests/fixtures/`, so harnesses are in scope by
name. Enforced by
`scripts/check-enumerate-helper-required.sh` (member check
`enumerate-helper-required` in the `lint-script-hygiene` CI group); see
[enumerate-helper-required](../docs/security/workflow-hardening.md#enumerate-helper-required).

Environment-variable overrides scoped to test invocation (a selection
of the most commonly needed, not the full set — each script's own
source is the canonical list):

| Variable                             | Script                                                                                                                                                                                                                        | Purpose                                                                                         |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `WORKFLOWS_DIR_OVERRIDE`             | every workflow-scanning script that takes this scan-root override — mostly lints, plus the docs-audit pressure meter; others use a differently-named one — enumerate with `grep -rlE '^[^#]*WORKFLOWS_DIR_OVERRIDE' scripts/` | swap the workflows scan root                                                                    |
| `WORKFLOW_FILE_FILTER`               | every workflow-scanning lint that supports single-file narrowing — enumerate with `grep -rlE '^[^#]*WORKFLOW_FILE_FILTER' scripts/`                                                                                           | restrict to a single fixture file                                                               |
| `LINT_ALLOW_EMPTY_SCAN`              | every lint that enumerates through `scripts/lib/enumerate.sh`, which honours the variable without the caller naming it — enumerate with `grep -lE 'glob_into\|enumerate_into\|filter_into' scripts/*.sh`                      | accept a deliberately empty scan set (see `docs/development/linting.md`)                        |
| `RENOVATE_JSON_OVERRIDE`             | `check-renovate-invariants.sh`, `check-renovate-markers-matched.sh`, `check-renovate-config-validator.sh`                                                                                                                     | swap the renovate.json path                                                                     |
| `SCAN_ROOT`                          | `check-renovate-markers-matched.sh`                                                                                                                                                                                           | swap the scanned tree root                                                                      |
| `SCAN_ROOT_OVERRIDE`                 | `check-doc-cron-restatement.sh`                                                                                                                                                                                               | swap the scanned tree root                                                                      |
| `RELEASE_TAG_RULESET_JSON_OVERRIDE`  | `check-tag-protection.sh`                                                                                                                                                                                                     | swap the release-tag-protection ruleset JSON                                                    |
| `PROTECT_MAIN_RULESET_JSON_OVERRIDE` | `check-protect-main.sh`                                                                                                                                                                                                       | swap the protect-main ruleset JSON                                                              |
| `PIN_FILE_OVERRIDE`                  | `bump-linpeas.sh`, `gen-dashboard-data.sh`                                                                                                                                                                                    | swap the linpeas-pin.json path                                                                  |
| `UPSTREAM_RELEASE_JSON_OVERRIDE`     | `gen-dashboard-data.sh`                                                                                                                                                                                                       | swap upstream release JSON (singular: the latest-release payload)                               |
| `UPSTREAM_RELEASES_JSON_OVERRIDE`    | `gen-dashboard-data.sh`                                                                                                                                                                                                       | swap upstream releases-list JSON (plural: the release enumeration)                              |
| `LATEST_RELEASE_JSON_OVERRIDE`       | `gen-dashboard-data.sh`                                                                                                                                                                                                       | swap rvenutolo release JSON                                                                     |
| `THIS_REPO_RELEASES_JSON_OVERRIDE`   | `gen-dashboard-data.sh`                                                                                                                                                                                                       | swap rvenutolo releases-list JSON                                                               |
| `BUMP_PR_JSON_OVERRIDE`              | `gen-dashboard-data.sh`                                                                                                                                                                                                       | swap the last-bump PR search payload                                                            |
| `PARITY_JSON_OVERRIDE`               | `gen-dashboard-data.sh`                                                                                                                                                                                                       | swap the parity-run payload                                                                     |
| `OUT_FILE_OVERRIDE`                  | `gen-dashboard-data.sh`                                                                                                                                                                                                       | redirect the generated YAML — use it so a test never writes the real `docs/_data/dashboard.yml` |

Each script defines its own overrides — check the script for the
canonical list before writing a new test. The two scan-root overrides
are listed one script at a time rather than behind an enumerating grep,
because each lint spells the variable differently: a grep for the
shorter of the two names both scripts, one of which ignores the
variable it matched and would scan the live repo instead of the fixture.
The `^[^#]*` anchor on the enumerating greps that remain keeps them off
comment-only mentions: a lint can name another lint's override variable
in a rule comment without consuming it,
which a bare substring grep reports as a consumer. The two ruleset
overrides are named for the ruleset each lint reads: one variable shared
between them would feed a single fixture to both whenever one process
runs the pair.

## Adding a fixture

1. Pick the script you are testing. Create
    `tests/fixtures/<script-name>/` if it does not exist.

1. Add a fixture file. Name with the convention:

    - `good.<ext>` (or `good-<scenario>.<ext>`) — script must exit 0.
    - `bad-<failure-mode>.<ext>` — script must exit non-zero with a
        specific stderr substring.

    The extension is whatever the subject lint reads — `.yml` for the
    workflow scanners, but `.sh`, `.json`, `.md` and others elsewhere.

1. Add an assertion line — `expect`, or `run_scenario` with a leading
    scenario name, matching whichever shape the harness already uses —
    for example:

    ```bash
    expect bad-new-mode.yml 1 "stderr substring identifying the failure"
    ```

1. Record the scenario with the discrimination gate, if the harness's
    scenario runner does not already do it for every `expect` line:

    ```bash
    harness_assert_record 'bad-new-mode' "${expected_stderr}" "${stderr_file}"
    ```

1. Run `nix develop --command bash tests/<script-name>.test.sh` locally to
    verify. A
    `does not discriminate` line means the chosen substring also
    appears in another scenario's output — pick a token unique to the
    failure path (typically the level tag plus the label rather than
    the bare label) and re-run.

1. Make sure `_typos.toml` still excludes `tests/fixtures/**` —
    fixture content is often intentionally malformed.

1. Regenerate the census: run
    `nix develop --command bash scripts/refresh-test-harnesses.sh` and
    commit the updated `docs/reference/test-harnesses.md`. A new fixture
    directory changes it, and the `test-harnesses-fresh` pre-commit hook
    only `--check`s the file — it rejects the commit rather than writing
    it.

## Adding a new test harness

1. Write the script's invariant first. Do not commit it on its own —
    the `script-has-test` hook runs over the whole tree whenever a
    `scripts/check-*.sh` is staged and rejects a check script with no
    matching harness, so the script and its harness land in one commit.

1. Create `tests/<script-name>.test.sh` mirroring the existing
    harnesses' shape (env-var overrides; an `expect` or `run_scenario`
    scenario runner).

1. Declare exactly one subject. A harness that assigns
    `SCRIPT="${REPO_ROOT}/scripts/<name>.sh"` already declares its
    subject through that assignment. A harness that does not — one whose
    target is an awk program, a Nix file, a whole file set, or another
    harness — must carry a `# @subject <path or file set>` line in its
    header comment block naming what it exercises. Carrying both is an
    error, and so is carrying neither:
    `scripts/refresh-test-harnesses.sh` exits 2 either way rather than
    rendering an unknown subject. A harness that reaches its fixture
    directory only through an override, so that no path literal in the
    file names it, adds a `# @fixtures <path>` line the same way.

1. Create `tests/fixtures/<script-name>/` with at least one `good`
    and one `bad-*` fixture.

1. Wire the harness to the discrimination gate: source
    `scripts/lib/harness-assert.sh`, call `harness_assert_record` for
    every scenario, and call `harness_assert_verify` at the end of
    `main`. A harness that asserts produced artifact content — a
    rewritten workflow file, a generated doc — rather than captured
    scenario output belongs on the `EXEMPT` array in
    `scripts/check-harness-assert-wired.sh` with a rationale comment
    instead. A harness that asserts without a quiet `grep` is outside
    the gate's wiring verdict and needs neither — but both exemption
    ratchets still cover it.

1. Register the harness so it actually runs.
    `scripts/check-test-reachable.sh` accepts four runners, and a
    harness reachable by none of them is a coverage no-op that still
    satisfies the pairing guard:

    - add the invariant name to `.github/lint-groups.yml` if the
        `check-<name>.sh` + `check-<name>.test.sh` pair belongs to a
        lint group — that manifest holds the name with its `check-`
        prefix and `.test.sh` suffix stripped, and
        `scripts/run-lint-group.sh` re-derives both paths from it;
    - add it to the `HARNESSES` array in
        `scripts/run-harness-group.sh` if it is a standalone harness;
    - name it `tests/refresh-*.test.sh` to be picked up automatically
        by `scripts/run-doc-freshness.sh`'s glob;
    - or invoke it directly from a `.github/workflows/*.yml` step, the
        way the `dashboard-data-tests` job runs
        `tests/gen-dashboard-data.test.sh`. This is the right shape when
        the harness needs a dedicated job rather than a slot in a
        batched one.

1. Regenerate the census: run
    `nix develop --command bash scripts/refresh-test-harnesses.sh` and
    commit the updated `docs/reference/test-harnesses.md`. The
    `test-harnesses-fresh` pre-commit hook only runs the generator in
    `--check` mode, so it rejects the commit rather than writing the
    file, and no `just` recipe wraps it.

1. Regenerate the script reference: run `just show-scripts` and commit
    the updated `docs/reference/scripts.md`. `scripts-reference-fresh`
    fires on any staged `scripts/*.sh`, so a new check script blocks the
    commit until its annotations are rendered — the census step above
    covers only the harness table.

1. If the script is wired into a CI required check, also document
    it in `docs/security/required-checks.md` and ensure
    `scripts/check-required-checks-no-paths.sh` covers the new
    workflow file.
