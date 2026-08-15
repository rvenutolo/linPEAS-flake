# Workflow-hardening invariants

Per-job hardening rules enforced across every workflow in `.github/workflows/`. Most rules are locked in by a script lint, run as a member check of a batched lint group job (`lint-workflow-security`, `lint-script-hygiene`, or `lint-doc-invariants`) and as a pre-commit hook. A few differ: some are enforced by a standalone CI job (`setup-nix-required`), some by CI only with no hook (`test-reachable`), and some are convention-only with no automated enforcer (lean lint-shell routing). See the [enforcement matrix](enforcement-matrix.md) for the authoritative per-rule mapping.

See [workflow-scanner division of labor](workflow-scanners.md) for how these
in-tree lints fit the broader layered scanning model (pre-commit → PR/push →
weekly sweep → watchdog) alongside the external scanners.

## job-timeout-minutes

Every job declares an explicit `timeout-minutes` as a positive integer.

GitHub Actions defaults a job timeout to 6 hours. A hung job at that ceiling burns the runner budget and stalls the merge queue. Requiring an explicit per-job value bounds the blast radius of any wedge and forces a deliberate choice when a job is added.

Reusable-workflow callers (jobs that use `uses: ./.github/workflows/<file>.yml`) are exempt because `timeout-minutes` is not valid on that shape; the timeout belongs in the called workflow's jobs.

Enforced by `scripts/check-job-timeout-minutes.sh`. Wired as the `lint-workflow-security` CI job (member check `job-timeout-minutes`) and as a pre-commit hook.

## workflow-concurrency

Every workflow declares a top-level `concurrency:` block with a non-empty `group:`.

Without a concurrency group, cron pile-ups and back-to-back PR pushes can spawn parallel runs on the same ref. Beyond burning runner minutes on superseded work, parallel runs can race steps that touch shared remote state (`gh release create`, tag pushes, image manifest writes). Forcing every workflow to declare a group keeps each ref serialized to one in-flight run by default.

`cancel-in-progress` is not required by this lint; the group alone is the load-bearing setting. Pipelines that must run to completion once started (e.g., `release-on-bump.yml`) deliberately set `cancel-in-progress: false` so back-to-back triggers queue instead of cancelling.

Enforced by `scripts/check-workflow-concurrency.sh`. Wired as the `lint-workflow-security` CI job (member check `workflow-concurrency`) and as a pre-commit hook.

## checkout-persist-credentials

Every `actions/checkout` step sets `with.persist-credentials: false` (boolean, not string).

Without it, `actions/checkout` writes `GITHUB_TOKEN` into `.git/config` and leaves it on disk for the remainder of the job. Any later step in the same job — a third-party action, a misbehaving binary, a shell injection in a `run:` block — can read the token from the working tree and use its scopes. `persist-credentials: false` drops the credential after the initial clone/fetch, narrowing the blast radius of a compromised later step.

Boolean `false` is required; the string `"false"` does not satisfy `actions/checkout`'s parsing.

Enforced by `scripts/check-checkout-persist-credentials.sh`. Wired as the `lint-workflow-security` CI job (member check `checkout-persist-credentials`) and as a pre-commit hook.

## upload-artifact-strict

Every `actions/upload-artifact` step sets `with.if-no-files-found: error`.

The action's default is `warn`, which silently uploads an empty artifact when the `path:` glob matches nothing. That hides build-output drift: a broken path produces a green job with no artifact, and the consumer side only notices when something downstream goes missing — sometimes many runs later. `error` turns the path-mismatch into a hard upload failure, surfacing the bug at its source.

Enforced by `scripts/check-upload-artifact-strict.sh`. Wired as the `lint-workflow-security` CI job (member check `upload-artifact-strict`) and as a pre-commit hook.

## workflow-on-branches

Every workflow that declares `on.pull_request:` or `on.push:` sets `branches: [main]` exactly under that trigger. No wildcards, no implicit all-branches, no other branch names.

Without the allowlist, Actions fires the workflow on every branch — burning runner minutes on stale topic branches and attaching surprising status checks to refs nobody is watching. Workflows that only run on `schedule:`, `workflow_dispatch:`, or `workflow_call:` are unaffected; `pull_request_target:` is handled by a separate lint that forbids it outright.

Enforced by `scripts/check-workflow-on-branches.sh`. Wired as the `lint-workflow-security` CI job (member check `workflow-on-branches`) and as a pre-commit hook.

## pull-request-target-absent

No workflow uses the `pull_request_target` trigger.

`pull_request_target` runs the **base** ref's workflow definition with the full secret scope of the base repo. If the workflow then checks out the PR head (the common reason to use this trigger), an attacker's fork PR can introduce malicious code that the base-ref workflow runs with secret access — the canonical Actions privilege-escalation footgun.

This repo has no use for the trigger. The lint hard-fails any workflow that adopts it. Removing the ban requires deleting this script, its `pull-request-target-absent` member entry under `lint-workflow-security` in `.github/lint-groups.yml`, and the pre-commit hook.

Enforced by `scripts/check-pull-request-target-absent.sh`. Wired as the `lint-workflow-security` CI job (member check `pull-request-target-absent`) and as a pre-commit hook.

## auto-merge-decline-gate

Every workflow run-block that calls `gh pr merge` with `--auto` also carries the decline gate: a `gh pr view --json state` query and a `CLOSED|MERGED` arm that exits non-zero.

An auto-merging update workflow recreates a per-period branch and merges its PR unattended. Without inspecting PR state first, a re-run in the same period overwrites a PR the maintainer explicitly closed (declined) or one already merged — silently reversing a human decision in a no-review flow. The gate aborts non-zero on `CLOSED|MERGED` so the run fails and a failure issue is filed instead.

This protects only an explicitly closed or merged PR; routine PRs are unaffected, so the fully-automated update flow is preserved.

Enforced by `scripts/check-auto-merge-decline-gate.sh`. Wired as the `lint-workflow-security` CI job (member check `auto-merge-decline-gate`) and as a pre-commit hook.

## script-shebang-pipefail

Every executable under `scripts/` starts with `#!/usr/bin/env bash` (exact first line) and contains `set -Eeuo pipefail` somewhere in the file.

A script that silently swallows a failure can corrupt `linpeas-pin.json`, skip a security check, or leave a stale build artifact behind. `set -Eeuo pipefail` plus a portable shebang are the hardening minimum: `-e` aborts on any command failure, `-E` propagates ERR traps into subshells, `-u` rejects unset variables, `-o pipefail` makes a pipeline fail when any stage fails (not just the last).

The lint accepts longer set lines (e.g. `set -Eeuo pipefail -x`) as long as the exact `-Eeuo pipefail` token is present.

The scan recurses, and a file under a `lib/` component is held to the inverse rule instead. A sourced library runs inside whichever shell sources it, so the executable rule is not merely unnecessary there — it is wrong. A library that sets `set -Eeuo pipefail` itself overrides whatever the caller chose, and a shebang advertises a file meant to be run rather than sourced. So a library must carry a `shellcheck shell=` directive (with no shebang, nothing else states the dialect), must not open with a shebang, and must not carry a shell-option line of its own. Each of the three failures prints its own message naming the half that broke.

Classification is by path, not by content: "no shebang means library" would excuse exactly the executable that forgot one, which is half of what this lint exists to catch.

Recursion matters because the shared libraries under `scripts/lib/` are where a single defect reaches every caller at once — `enumerate_into` alone decides whether a failed enumeration becomes exit 2 for every lint that uses it.

Enforced by `scripts/check-script-shebang-pipefail.sh`. Wired as the `lint-script-hygiene` CI job (member check `script-shebang-pipefail`) and as a pre-commit hook.

## lib-source-tool-free

A script under `scripts/`, sourced libraries included, never resolves a `source`/`.` library path through a command substitution — whether the substitution names `BASH_SOURCE` or invokes some other tool entirely — and `BASH_SOURCE` never appears inside a command substitution anywhere else in the file either.

`BASH_SOURCE[0]` is how a script locates its own directory to source a shared library. Feeding it through a command substitution such as `$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")` needs `readlink` and/or `dirname` on PATH, and runs above the guard whose whole job is naming a missing tool. A script whose PATH lacks either tool dies at exit 127 naming `readlink` — a could-not-run reported under neither the exit code this repo reserves for it (2) nor a diagnostic naming what was actually absent. That holds wherever the substitution sits: directly on the `source` line (`source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/log.sh"`), or one line earlier into a variable the `source` line only reads (`_lib_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"` followed by `source "${_lib_dir}/lib/log.sh"`) — the second placement dies exactly the same way under a stripped PATH, so this half of the rule scans every line of every file rather than source lines alone.

A `source`/`.` line can also shell out to build its path without ever naming `BASH_SOURCE` — `source "$(git rev-parse --show-toplevel)/scripts/lib/log.sh"` dies exactly the same way under a stripped PATH, at whatever tool the substitution invokes. This half of the rule is scoped to library source lines: a path under a `lib/` directory, or any source line inside a file that is itself under a `lib/` directory (a library resolving a sibling). Both are structural tests on the line and the file rather than a list of library basenames, so a library added later stays covered without the lint itself needing an update.

`${BASH_SOURCE[0]%/*}` needs nothing on PATH: the shell performs the trim itself, with a `.` fallback for a bare-filename invocation where the expansion strips nothing. A bare `${BASH_SOURCE[0]%/*}` with no bare-filename fallback stays legal: it is tool-free, and the case it misses is an invocation no caller in this repo makes. A library that sources a sibling resolves its own directory into `_lib_self_dir` rather than `_lib_dir`, because `source` runs in the caller's scope and reusing the caller's variable name would clobber it partway through the caller's own subsequent `source` lines — that shape stays clean too. A comment line may still name either banned shape without tripping the check on its own documentation.

The two halves report distinct diagnostics — one names `BASH_SOURCE` explicitly, the other names a library source path — so an operator can tell which rule fired without reading the line itself.

Breadth is asserted on the same count the source-path half of the rule scans: a clean run reports how many library `source .../lib/*.sh` lines it read, and reading zero is scored as a could-not-run rather than a clean tree, whether the scan root holds no shell script at all or holds scripts that never source a library. `LINT_ALLOW_EMPTY_SCAN=1` suppresses that guard for a scan root that deliberately holds none.

Enforced by `scripts/check-lib-source-tool-free.sh`. Wired as the `lint-script-hygiene` CI job (member check `lib-source-tool-free`).

## no-opaque-procsub

No script anywhere under `scripts/`, sourced libraries included, feeds a redirection from a process substitution — `done < <(yq eval '.x' "$f")`, `mapfile -t rules < <(jq --raw-output '.rules[].type' <<<"${json}")`, `done < <(find . -name '*.sh')`, `done < <(parse_blocks)` and every variant of the shape. There is no exemption marker and no allowlist.

A process substitution's exit status is invisible to `set -Eeuo pipefail`: the substitution runs in its own subshell, and the shell only ever sees the exit status of the command the redirection feeds (here, the `while`/`done` loop or `mapfile`), not the producer's. When the producer fails, the substitution produces empty output and the consumer scores that emptiness as data. Which way that lands depends on what the consumer does with an empty result, and both landings are wrong:

- A scan loop exits 0 as if it found nothing to flag — a fail-open masquerading as a clean pass.
- An assertion loop reports the substantive violation that an empty result implies — a missing ruleset rule, a dead dependency marker — sending the operator to fix input that was never wrong, while the producer fault itself is reported only as stray stderr.

The rule does not ask what the producer is, because the property does not depend on it: a parser, a `find`, a `git ls-files`, or a helper function the same file defines all lose their status the same way. Judging the shape rather than the producer keeps the rule decidable in a single textual pass and keeps it true when a helper grows a `git`, `find`, or `nix` call.

The sanctioned idioms make the failure abort loudly instead: capture the producer's output into a variable first (`hits="$(yq eval '.x' "$f")"`, then iterate with `<<<"${hits}"`) so `set -e` catches a non-zero exit before the loop ever runs; or, for NUL-delimited output that can't round-trip through `"$(...)"` (command substitution strips embedded NUL bytes), write to a temp file and iterate with `< "${tmp}"`. A capture that is legitimately empty needs an explicit `[[ -n … ]]` guard, since a bare here-string feeds one empty line rather than zero.

A tooling failure caught this way exits 2, keeping exit 1 for the drift the check exists to report.

The ban covers redirections only. `diff <(jq …) <(jq …)` and `diff <(expected_keys) <(actual_keys)` stay legal: `diff` consumes both substitutions as file arguments and its own status is what the script acts on.

The lint skips comment lines (lines whose first non-whitespace character is `#`) so a script is free to document the banned idiom by name — e.g. explaining why it uses the capture idiom instead — without tripping the check on its own documentation.

Enforced by `scripts/check-no-opaque-procsub.sh`. Wired as the `lint-script-hygiene` CI job (member check `no-opaque-procsub`) and as a pre-commit hook.

## guard-exit-code

No script anywhere under `scripts/`, sourced libraries included, exits 1 out of a guard whose test is only an availability check. The three exit codes separate what the operator has to do about a run:

- **2** — the check could not run: a required tool is absent, or an input is missing, unreadable or malformed. Nothing was inspected, so there is no verdict about the repo.
- **1** — the check ran and found a violation. The repo needs fixing.
- **0** — clean.

Reporting an absent tool as 1 sends the operator hunting for drift in content the check never read, and a hook or job that reports both the same way makes a broken environment indistinguishable from a broken repo. Exit 2 still fails the hook and the job, so the verdict is unchanged and only the diagnosis improves.

A hit is a conditional whose test is *purely* an availability predicate and whose branch body exits 1 — `if ! command -v X`, `if ! require_tool X`, `if [[ ! -f|-r|-e|-d|-s PATH ]]`, or the brace-group form `[[ -f PATH ]] || { … }`.

Matching is branch-scoped rather than proximity-based. The lint walks the branch body from its opening keyword to the matching `fi` or closing brace, so an exit that merely sits a few lines below an availability test is not attributed to it. That distinction carries the rule: several checks here read a marker or a field out of a file that exists and report its absence as the finding — a doc that lost its managed `BEGIN`/`END` markers, a `flake.nix` missing its pinned hooks SHA URL, a `cliff.toml` missing `tag_pattern`. Those exits belong to the search that came back empty, not to the guard above them, and a line-window scan attributes exactly those to the wrong guard.

A test that mixes an availability predicate with another predicate under `||` — `[[ ! -f ${out} ]] || ! cmp --silent -- "${out}" "${tmp}"` — is not a hit. That branch is reachable without anything being absent, so absence there is half of a content verdict rather than a could-not-run. An `&&` chain carrying an availability predicate *is* a hit, because the whole chain then requires the thing to be absent.

The escape hatch is `# exit-code-exempt: <rationale>` on the exit line, for a guard whose missing input genuinely is the finding. The marker has to open the comment, so prose naming it exempts nothing, and the rationale has to be non-empty — a marker with an empty rationale is its own diagnostic rather than a silent pass. A clean run prints the exemption count, so the exempt set is stated rather than open-ended.

Whole-line comments are blanked before matching, so a script may document the banned shape by name without tripping the check on its own documentation.

### Bare temp-file creation

The same lint bans a second shape, which lands on the wrong side of the same convention one level down: a bare `mktemp` anywhere under `scripts/`.

An unwritable or absent `TMPDIR` makes `mktemp` exit 1. Under `set -Eeuo pipefail` an unguarded `tmp="$(mktemp)"` propagates that status, so the script dies with 1 — the code reserved for "this repo carries a violation". A pre-commit hook or CI job reads that as a stale tree and sends the operator to edit content the check never read, when what actually happened is that the machine could not hand the script a scratch file.

Every creation therefore routes through `make_temp` (`scripts/lib/temp.sh`), which passes its arguments to `mktemp` verbatim, prints the created path, and on failure prints `<script>: cannot create a temp file (TMPDIR=<dir>)` and exits **2**. Exiting from inside the command substitution propagates through the enclosing assignment, so a call site needs no guard of its own.

A hit is the command in *command position* — after line start, `$(`, a pipe, a `;`, a `!`, a `{`, an `&`, or a `then`/`do`/`else` keyword, with an optional `command` prefix. A bare `(` is deliberately not an introducer, so a parenthetical such as "atomic (mktemp + mv) pin write" is not a hit; neither is a trailing comment, a string operand, or a whole-line comment naming the command. The rule is switched off for `scripts/lib/temp.sh` alone, by basename — that library holds the one sanctioned invocation, and every other rule in this lint still reads it.

The escape hatch is the same `# exit-code-exempt: <rationale>` marker, on the creation line, for a call whose failure genuinely is the finding. Both rules share one marker implementation, so an empty rationale is a diagnostic on either of them rather than a silent pass, and both feed the same exemption tally a clean run prints.

Enforced by `scripts/check-guard-exit-code.sh`. Wired as the `lint-script-hygiene` CI job (member check `guard-exit-code`).

## path-hygiene

No path git reports for the tree — tracked, or untracked and not ignored — may carry a byte in the 0x01-0x1F control range or DEL (0x7F).

A path is the one shell datum whose byte space includes the newline delimiter. A filename carrying one reads as two records to any line-oriented consumer: `git ls-files` (without `-z`) C-quotes it onto a single output line, `find` (without `-print0`) splits it across two, and either way a downstream `[[ -f ]]` gate can skip a file that exists while the scan that produced the list still reports a plausible count. `scripts/lib/enumerate.sh` closes this for every converted producer/consumer pair by reading NUL-delimited output; this lint closes it for every consumer the conversion cannot reach, by refusing to let a name in that class exist in the tree at all.

Tab (0x09) is in scope for the same reason, one level down: several of this repo's own inventories — the harness discrimination census, the enforcement-matrix table — are tab-separated, so a tab inside a path corrupts those exactly as a newline corrupts a line-oriented handoff. Both bytes fall inside the 0x01-0x1F range the lint bans, so no special-casing is needed to cover either one.

The scan covers `git ls-files --cached --others --exclude-standard`: tracked paths plus untracked-but-not-ignored ones. The untracked half matters for the reason `check-ephemeral-refs.sh` scans the same way — a file a commit is about to introduce is gated by the same run that introduces it, not by whichever run happens to follow the commit that adds it.

A hit is reported with the offending path rendered through `${path@Q}`: the path is otherwise attacker-controlled text passed straight to this lint's own diagnostic output, and `@Q` renders every control byte in it as a `$'...'` escape sequence rather than printing it raw, so a crafted name cannot forge a fake report line into the lint's own output.

Enforced by `scripts/check-path-hygiene.sh`. Wired as the `lint-script-hygiene` CI job (member check `path-hygiene`).

## awk-operand-explicit

Every `awk` invocation in `scripts/*.sh` that carries a file operand spells that operand `"$(awk_path "${var}")"`.

`awk` reads a command-line operand shaped `name=value` as a variable assignment rather than a filename. Given one, it finds no file operand, reads stdin instead, and exits 0 having scanned nothing — so a relative path whose first path component contains `=` (e.g. `a=b/file.sh`) silently scores as an empty file rather than failing loud. `--` is no defense: POSIX makes operand-assignment parsing independent of it, and gawk treats a `--` placed after the program as a filename rather than an end-of-options marker. `scripts/lib/awk-path.sh`'s `awk_path()` neutralizes the hazard by prefixing a relative path with `./` (conditionally — an absolute path is returned unchanged, since a `./` ahead of one resolves as a different, relative path); this lint is what keeps every future `awk` call wrapped, rather than trusting a one-time sweep of the existing call sites to hold forever.

Detection parses each script's shell syntax tree via `shfmt --to-json` — the same `mvdan.cc/sh` parser `shfmt` and `treefmt` already run over this repo — rather than matching text, because a textual rule drifts the moment a script's formatting moves an operand onto another line, inside a multi-line awk program, or beside a sibling operand. A call is recognized as an awk invocation whether it spells the command word `awk`, `gawk`, `mawk`, or `nawk`; via a path ending in one of those basenames (`/usr/bin/awk`); via a `command`-prefixed form (`command awk`); or via a statically-quoted literal (`"awk"`) — not only the bare `awk` literal.

For every such call, the argument list is walked following awk's own flags-then-program-then-operands grammar: `-v`, `-F`, `-f`/`--file`, `--field-separator`, `--assign`, `--source`, and their attached forms (`-F'\t'`, `--field-separator=x`, `-fprog.awk`, `--file=prog.awk`) are all recognized as flags regardless of whether a program has already been supplied, so a legally-repeated `-f a.awk -f b.awk` is not misread as carrying operands on `-f` or `b.awk`. `-f`, `--file`, and `--source` each supply program text (a repeated one concatenates, which is legal), so any of them marks the program as already established; `--assign` does not, since it never supplies one. Only the first non-flag word establishes the inline program, and only when none of `-f`/`--file`/`--source` already has; every non-flag word after that is an operand. `--` is itself flag-shaped, but its meaning depends on what came before it: while the program is still pending, `--` ends option parsing as usual and the word right after it becomes the program; once the program is already established, gawk instead reads a further `--` as an ordinary filename, so the walk folds it back into "this is an operand" rather than ending anything. `-f`/`--file`'s own value and the program text itself are excluded from the operand list, since neither was ever a file operand. Every operand that survives must be exactly one double-quoted word wrapping a single command substitution that calls `awk_path`; anything else is a violation.

Not operands, and therefore never reach the walk: stdin redirections (`awk 'prog' <"${f}"`) and here-strings (`awk 'prog' <<<"${v}"`) — a redirection attaches to the enclosing statement, not the command's own argument list, so a call fed one has zero operand arguments to inspect — and pipeline input (`producer | awk 'prog'`), for the same reason.

The total operand count checked across a run is itself asserted nonzero, unless `LINT_ALLOW_EMPTY_SCAN=1` — the same variable `check-doc-anchors.sh` already uses to gate its own "0 anchor links found" case, reused here rather than a dedicated flag because the shape is identical: enumeration succeeded, but the count of the thing being verified came back zero, and that has to be stated as deliberate rather than inferred. Without this assertion, a classifier regression that silently drops every operand from its accounting would still print a clean "0 violations" summary and exit 0 — the same failure mode `scripts/lib/enumerate.sh` exists to close at the file-enumeration level, one level further in, at the level of what each enumerated file was found to contain.

Enforced by `scripts/check-awk-operand-explicit.sh`. Wired as the `lint-script-hygiene` CI job (member check `awk-operand-explicit`).

## enumerate-helper-required

Every filesystem enumeration in a repo script runs through `enumerate_into` (`scripts/lib/enumerate.sh`). A producer — `find`, `git ls-files`, `git ls-tree` — may appear in exactly three positions: as an argument to the helper, inside a function the helper is handed by name, or behind an inline `# enumerate-exempt: <rationale>` marker whose rationale is non-empty (an empty one is drift, not an exemption, exactly as the sibling exit-code and patch-tag markers treat it).

Every glob-driven scan fills its array through `glob_into`, the same library's glob analogue. A `for` loop may not expand a pattern at its own loop head unless an inline `# glob-exempt: <rationale>` marker says an empty match set is that loop's normal state; the rationale is held to the same non-empty rule.

The property being protected is scan **breadth**, not producer status. A producer that fails is the easy half; the hard half is a producer that succeeds and enumerates nothing. `GIT_INDEX_FILE=/nonexistent git ls-files` exits 0 and prints not one path — which every status check reads as a clean tree. A lint handed an empty scan set finds no violations and exits 0: off, and green. So breadth has to be asserted rather than inferred, and the helper is where that assertion lives; routing every enumeration through it makes the assertion structural instead of something each call site has to remember.

The glob loop fails the same way from the other end. Under `nullglob` a pattern that matches nothing expands to nothing, the loop body never runs, no violation is found and the run exits 0 — so a scan root that exists and holds nothing scores as a clean tree, and the operator override that points the scan somewhere useless reads exactly like a repo with nothing to fix. `glob_into` carries that assertion: it expands the patterns itself, fills the named array, and refuses an empty match set unless `LINT_ALLOW_EMPTY_SCAN=1`. The loop then walks an ordinary array.

That is also what makes both rules decidable in one pass. Associating a scan with a cardinality test written an arbitrary distance later is not something a textual rule can do. Asking whether a producer is an argument to the helper is local to a single call expression, and so is asking whether a `for` loop expands a pattern at its own head. The glob rule rests on one further structural property: a pattern handed to `glob_into` is an argument of a `CallExpr` and never a `WordIter` item of a `ForClause`, so a compliant call site cannot false-hit however many metacharacters its arguments carry.

Detection parses each script's syntax tree via `shfmt --to-json` rather than matching text, because three shapes name these commands without running them and a textual rule would need a special case for each: the lint's own prose, the label string every compliant call site passes (`enumerate_into paths 'git ls-files' git ls-files -z …`), and heredocs documenting the idiom. None is a command node, so none is a hit. A `git` invocation's subcommand is found by walking past the global flags (`-C <dir>`, `-c <k>=<v>`), not by reading the word straight after `git`.

The glob rule reads the same tree: a `ForClause` whose `WordIter` items carry `*`, `?` or `[` in a bare `Lit` part. Only a bare literal counts — a metacharacter inside quotes is not a pattern, so `for x in "*"` iterates one literal asterisk and asserts nothing about any tree — and a C-style `for ((;;))` has no items at all.

Each rule owns its own marker word, keyed off the kind of site the record names. A `# enumerate-exempt:` rationale does not excuse a glob loop and a `# glob-exempt:` rationale does not excuse a producer, because a reason for running a producer outside the enumeration helper is not a statement about whether a match set may come back empty. One shared word would opt a site out of both rules on the strength of whichever one its author happened to think about.

The count of scan sites classified — producer calls, `glob_into` call sites and glob loops together — is itself asserted nonzero unless `LINT_ALLOW_EMPTY_SCAN=1`. A grammar that stopped recognizing either subject would report "0 violations" and exit 0 — the same line a genuinely scan-free tree prints — leaving this gate off while green, which is the exact failure it exists to prevent one level down. Counting the sanctioned `glob_into` calls, not only the loops that violate the rule, is what makes the tally cover the glob rule at all: a tree that had converted every site would otherwise contribute nothing to it.

Enforced by `scripts/check-enumerate-helper-required.sh`. Wired as the `lint-script-hygiene` CI job (member check `enumerate-helper-required`).

## script-has-test

Every `scripts/check-*.sh` has a matching `tests/check-*.test.sh`, and every `tests/check-*.test.sh` has a matching `scripts/check-*.sh`.

The check-lint family is held together by naming convention: each lint script ships next to a fixture-driven test harness that validates the script's spec. Without enforcement, a new lint can land without tests and silently rot. The bidirectional pairing forecloses that.

`check-jsonschema` is exempt: it's a thin wrapper around the upstream `check-jsonschema` tool plus a schema bundle, so there's no spec-driven behavior worth unit-testing. New exemptions require updating the `EXEMPT` list in the script and justifying the entry in its comment.

Enforced by `scripts/check-script-has-test.sh`. Wired as the `lint-script-hygiene` CI job (member check `script-has-test`) and as a pre-commit hook.

## test-runner reachability

Every `tests/*.test.sh` harness is executed by at least one runner, so the coverage it represents is real rather than latent.

`check-script-has-test` guarantees a test *file* exists for each script; it does not guarantee the test ever *runs*. A harness wired into no runner is a coverage no-op — a regression it would catch merges green while the pairing guard stays satisfied. This asserts every harness is reachable via one of four runners: the `HARNESSES` array in `scripts/run-harness-group.sh` (the `harness-group` job), the `tests/refresh-*.test.sh` glob in `scripts/run-doc-freshness.sh` (the `doc-freshness` job), a `.github/lint-groups.yml` member resolving to `tests/check-<name>.test.sh` (run by `scripts/run-lint-group.sh`), or a direct `tests/<x>.test.sh` invocation in a `.github/workflows/*.yml`.

The `EXEMPT` list in the script is empty: every harness must be wired to a runner. A genuinely manual-only harness would be listed there with a rationale.

Enforced by `scripts/check-test-reachable.sh`. Wired as the `lint-script-hygiene` CI job (member check `test-reachable`).

## harness assertion discrimination

Every harness scenario asserts a substring that appears in no sibling scenario's output, and every harness asserting against captured scenario output is wired to the gate that checks it.

A harness proves behavior by grepping one scenario's captured output for a substring. When that substring also appears in a sibling scenario's output — a banner the script prints on the nominal path as well as the failure path, say — the grep matches whether or not the asserted behavior exists, so the harness stays green against a script that never implements it and the regression it was written to catch merges unseen. The gate records each scenario's asserted substring alongside its captured output and, after the run, flags any substring that also occurs in a sibling's output. Scenarios asserting the same substring are mutually exempt, and two records over byte-identical output are judged as a group rather than as two scenarios a substring fails to separate — see [harness census parity](#harness-census-parity). A harness wired to the gate that records nothing fails closed.

`harness_assert_exempt <substring> <other-scenario|*> <rationale>` registers a reviewed exception: the named form where one failure path emits no token another lacks, the `*` form for a banner a script prints across a whole outcome class. The rationale is mandatory so every weakening is reviewable, and the number of live registrations is held at zero — see [harness exemption ratchet](#harness-exemption-ratchet). A harness that asserts produced artifact content — a rewritten workflow file, a generated doc — rather than captured scenario output is listed on the `EXEMPT` array in `tests/_harness_assert_wired.test.sh` with a rationale comment.

Enforced by `scripts/lib/harness-assert.sh`, which runs inside every wired harness, and by `tests/_harness_assert_wired.test.sh`, which asserts the wiring; both are reached by the `harness-group` CI job.

## harness exemption ratchet

No harness registers a discrimination exemption, and a harness counts as wired to the gate only when it calls the verification function rather than naming it.

An exemption is sound at the moment it is written and silent afterwards. The shared banner it excuses gains a distinguishing token, or the sibling scenario it names is deleted, and the registration stays behind — accepting a substring that no longer needs accepting, in the one place built to notice that. Holding the count at zero prices the escape hatch at an edit to the ratchet itself, which is the review moment a weakened assertion deserves. `harness_assert_exempt` stays in `scripts/lib/harness-assert.sh` with its spec-test coverage so a genuinely shared banner keeps a relief valve; reaching for it means saying so in the same change.

Wiring is scored on a call because the gate reads harness source text. A header comment naming `harness_assert_verify`, or a commented-out call left in place, otherwise satisfies the check while nothing runs — the failure mode the gate exists to catch, reproduced inside the gate. Whole-line comments are blanked before matching, and the verify token must open a statement, optionally behind `if`, `||`, or `&&`. A trailing comment on a code line survives the blanking; the statement-anchored patterns reject it regardless, since the token is not the first word on its line.

The ratchet covers every harness, including those asserting by other means than the quiet-grep idiom, because an exemption registered by a harness outside the wiring gate's scope weakens the same library. `tests/lib-harness-assert.test.sh` is the one exclusion, on the `EXEMPT` array: the gate library's own spec test must not be gated by the library it tests, and its generated library-driving snippets are indistinguishable from live calls to any textual rule.

Enforced by `tests/_harness_assert_wired.test.sh`, reached by the `harness-group` CI job.

## harness census parity

No two scenarios in a harness share one whole observable outcome. A record is the exit code, the stdout and the stderr of one run taken together, and the gate fails when two records normalize to the same bytes unless a rationale-bearing exemption covers the pair.

Two scenarios the gate cannot tell apart verify one thing between them: whatever the second is meant to exercise, its entire observable outcome is already produced by the first, so deleting either leaves the recorded evidence unchanged and a regression that flips only the second merges green behind its twin. A harness at parity — as many distinct outcomes as scenarios — is one where every scenario earns its place. Each pair inside a collapsed group is judged on its own, so excusing one pair never excuses the rest, and the census names every surviving group by scenario instead of reporting a bare count: a named collapse is one a reviewer can act on, where a count is a number that drifts unread. The rule that every member of a group must claim the same substring set still applies to an excused pair — an exemption excuses a shared outcome, never a mismatched set of assertions.

`harness_assert_parity_exempt <scenario> <other> <rationale>` registers the exception, and the rationale carries a specific claim: the two scenarios differ in what they exercise, nothing they honestly emit says so, and no output the script could print would separate them without keying on fixture identity rather than on behavior. Unlike the discrimination hatch this one cannot be held at zero — a scenario can exist to refute an implementation that reads an input the real one deliberately never consults, and such a pair admits no separating output by construction. It is held to the `PARITY_EXEMPT_ALLOWED` list in `tests/_harness_assert_wired.test.sh` instead, each entry carrying the reason its pair is irreducible, so a second collapse costs an edit to that list under review.

A collapsed group is a measurement fault before it is a coverage fault, and reading it the other way around is the expensive mistake. A scenario whose clean run prints nothing still discriminates, through its exit code: mutate the script under test to drop a code path and that scenario goes red, which is exactly what a scenario verifying nothing could not do. What collapsed was the record, not the coverage — the gate was comparing one stream while the distinction lived in another. Treating such a group as missing coverage leads to inventing per-scenario chatter for the gate's benefit, which verifies nothing and weakens every later assertion in that harness by giving substrings more text to match by accident.

Both moves that reach parity are therefore about what gets recorded. Each record captures the whole observable outcome, so a distinction the script already draws is visible to the gate. Where scenarios still collapse, the script's own summary line widens to state the scope it verified — files scanned, mechanism matched, exemption applied, tags excluded — which is output a maintainer reads on its own merits and which separates the scenarios because it reports something that genuinely differs between them.

Enforced by `scripts/lib/harness-assert.sh`, which runs inside every wired harness, and by `tests/_harness_assert_wired.test.sh`, which holds registration to the allowlist; both are reached by the `harness-group` CI job.

## manifest-reaching hook watches nix/hooks

Every pre-commit hook that reaches the Nix hook manifest (`nix eval .#devTooling.<system>.preCommitHooks`) includes `nix/hooks` in its `files` filter. A hook reaches it either through the script its entry runs, or through a flake attribute its entry evaluates whose assigning module reads the manifest.

A freshness hook regenerates or validates a generated doc from the manifest. When its `files` filter omits `nix/hooks`, a commit that edits only a hook definition under `nix/hooks/*.nix` changes the manifest but does not re-trigger the hook on the per-changed-file `git commit` path, so a stale generated doc can be committed locally. The `--all-files` CI mirror still catches the drift, but the local fast-path defense is lost. Tying every manifest-reader's filter to `nix/hooks` keeps the local and CI paths in agreement.

The guard derives its subjects by content, not from a hardcoded list. A script subject is any `scripts/*.sh` naming `preCommitHooks` or `PRECOMMIT_HOOK_NAMES`; an attribute subject is a hook entry naming a flake attribute, and it qualifies when a module assigning that attribute names either token. Each qualifying hook's `files` filter must then contain `nix/hooks`. The guard fails loud when it finds no subjects of either class, and when a hook entry names a flake attribute that subject discovery did not pick up — both mean a parser break from a hook-file reformat rather than a clean tree.

Enforced by `scripts/check-manifest-hook-watches-nix.sh`. Wired as the `lint-script-hygiene` CI job (member check `manifest-hook-watches-nix`) and as a pre-commit hook.

## freshness hook watches evaluated sources

Every pre-commit hook whose entry evaluates a flake attribute names, in its `files` filter, every source that evaluation reads. Two hook shapes evaluate one: a generator script the entry runs, which reads `devTooling.<system>.<attr>`, and an entry that evaluates an attribute directly with `nix build` or `nix eval`, naming no script at all.

A freshness hook regenerates a doc from an evaluated flake attribute and refuses a stale commit. Its `files` regex decides which changed paths re-trigger it on the per-changed-file `git commit` path. When the filter misses a module the generator evaluates, a commit touching only that module leaves the doc stale with the guard silent. The `--all-files` CI mirror still catches the drift, but the local fast-path defense is lost, so the gap surfaces late.

The required source set is derived rather than hardcoded, per shape.

For a generator subject: modules naming the evaluated attribute in non-comment nix source, plus one level of their relative imports, plus modules assigning `flake.devTooling` — the transposition every generator reads through. The second signal is what makes the derivation structural. A module that merely mentions an attribute in a comment is not thereby required, and a module that performs the transposition is required whether or not it names the attribute at all.

For an attribute subject: `flake.nix` and `flake.lock`, since any flake evaluation reads both and a lock bump changes the packages the attribute resolves to; every module assigning the attribute, matched on the assignment shape so that merely naming the leaf does not qualify a module that is not a source of it; and one level of the relative paths those modules reference, of any extension — a module embedding `${../scripts/foo.sh}` genuinely depends on that script.

The guard is source-parsed rather than `nix eval`-ed: `files` and `entry` are literal in source, and `nix eval` is the known local-commit-path long pole. It fails loud if it finds no `devTooling`-evaluating generator, no hook running one, an attribute with no defining or assigning module, or a hook entry naming a flake attribute that subject discovery did not pick up — each of which means the derivation broke rather than that the tree is clean.

Enforced by `scripts/check-freshness-hook-watches-modules.sh`. Wired as the `lint-script-hygiene` CI job (member check `freshness-hook-watches-modules`) and as a pre-commit hook.

## lean lint-shell routing

The batched invariant-lint groups are split across two devShells by closure cost. The light groups — `lint-workflow-security` and `lint-script-hygiene` — run in `devShells.lint`, whose tight closure realizes far faster in CI than the full author shell. `lint-doc-invariants` must stay on `devShells.default`: its `renovate-config-validator` check invokes the `renovate` binary, which pulls the heavy renovate closure that the lean shell deliberately omits. Moving `lint-doc-invariants` to `.#lint` would break that check; moving the light groups back to `.#default` would forfeit the realize saving. A new batched group belongs in `.#lint` only if every tool it needs is in the `lintTools` list in `nix/devshell-lint.nix`; otherwise it stays on `.#default`.

## lint-shell-tools

The `lint-workflow-security` and `lint-script-hygiene` invariant-lint groups run inside the lean `devShells.lint` shell, which carries only the tools those groups need (bash, coreutils, gnugrep, gnused, gawk, findutils, yq-go, jq, gh, git, shellcheck, shfmt, actionlint, check-jsonschema) rather than the full author toolchain. The lean shell trades realize cost for a tighter closure, so a tool dropped from its declared list would surface only as a cryptic mid-check failure deep inside one of the batched groups.

`nix/devshell-lint.nix` declares that tool set once, as `lintTools`, and consumes it twice: as the `buildInputs` of `devShells.lint`, and as the `PATH` of the `checks.lint-shell-tools` derivation. The guard itself is one script asserting every expected tool resolves on the current `PATH`; two layers run it against two different environments.

- **The declared list.** `checks.lint-shell-tools` runs the guard with `PATH` set to exactly `lintTools` and nothing else, so a package dropped from the list fails the build naming that tool. The `lint-shell-tools` pre-commit hook builds this check, and `nix flake check` picks it up as a flake check. A hook that instead ran the guard against the committer's ambient `PATH` is vacuous for exactly the edit it watches: every expected tool is also in `devShells.default`, so a dropped package still resolves and the guard stays green.
- **The realized shell.** The `lint-script-hygiene` CI job runs the guard from inside `devShells.lint`, validating the shell that actually hosts the batched groups. Only this layer catches a tool that is declared yet does not land on `PATH` — a package whose binary carries a different name, or one shadowed by another shell input. Run inside `devShells.default`, the same invocation confirms the author shell remains a superset.

Both layers are wanted: the derivation checks the declaration, the CI job checks the realization. The expected-tool list lives in `scripts/check-lint-shell-tools.sh` and must stay in sync with `lintTools`; a missing tool becomes a named `::error::` line instead of an opaque downstream crash.

Enforced by `scripts/check-lint-shell-tools.sh`. Wired as the `lint-script-hygiene` CI job (member check `lint-shell-tools`) and as a pre-commit hook that builds `checks.lint-shell-tools`.

## ci-job-in-summary

Every `jobs.<name>:` in `.github/workflows/ci.yml` either appears as a key in `docs/_data/ci-check-categories.yml` or is on the lint's `EXEMPT` list of auxiliary jobs deliberately not exposed as required status checks. `EXEMPT` is currently empty: every `ci.yml` job is mapped. Conversely, every key in the category map corresponds to a real `jobs.<name>:` in some workflow file under `.github/workflows/`.

`refresh-ci-summary.sh` already enforces parity between the category map and `docs/security/required-checks.md`. This lint adds the ci.yml ↔ categories check, so a new required job that ships without a category mapping fails the PR rather than landing and breaking the pre-commit summary regenerator on the next commit.

Adding a new ci.yml job that should be a required status check requires updating the categories map, the required-checks doc, and the protect-main ruleset (in-tree and live). Adding an auxiliary job requires only an `EXEMPT` entry justified in the script comment. The list is self-policed: an entry must name a real `ci.yml` job that has no category-map key, so it cannot rot into a name that exempts nothing while the lint stays green.

The `EXEMPT` list is also the ci-job exemption source for the enforcement matrix: `scripts/refresh-enforcement-matrix.sh` reads it through this script's `--print-exempt` mode, so one declaration serves both checks and they cannot disagree about which auxiliary jobs are expected to have no invariant behind them. `--print-exempt` prints one job name per line and exits 0; an empty list prints nothing, so exit status — not output length — is what says the list is readable. The generator treats any nonzero exit as fatal, so a dropped or renamed mode aborts the refresh instead of quietly widening the orphan-job check to every unmapped job.

Enforced by `scripts/check-ci-job-in-summary.sh`. Wired as the `lint-doc-invariants` CI job (member check `ci-job-in-summary`) and as a pre-commit hook.

## run-block-strict

Every block-scalar or newline-carrying `run:` block under `.github/workflows/*.yml` (or `.yaml`) and `.github/actions/**/action.yml` (or `.yaml`) starts with `set -Eeuo pipefail` as its first non-blank, non-comment line.

Bash inside Actions `run:` blocks defaults to `-e` off. A failed command in the middle of a block that runs several commands silently continues, producing wrong results in security-critical jobs (release signing, attestation verify, pin write-back). The strict-mode prelude closes that gap.

Composite actions are covered for the same reason, and the exposure is larger there: a composite runs inside every job that calls it, so one block that swallows a failure swallows it across the whole workflow set. Composite steps hang off `runs.steps` instead of `jobs.<id>.steps`, so the lint reads both document shapes and names which one a violation came from (`job <id> step[n]` versus `composite step[n]`).

Adding the prelude to an existing block is a behavior change, not a formality: a command whose non-zero exit the block previously ignored will abort the step under `-e`. Blocks that tolerate failure by design — retry loops, optional probes — must keep the tolerated command in a context that consumes its status (an `if` condition, a `||` fallback) and say so, rather than relying on `-e` being absent.

The rule keys off YAML node style (`|`, `>`, and their chomping/indent variants) as well as newlines in the evaluated value. Newline presence alone under-detects: a folded scalar (`run: >-`) spells a `;`-separated command sequence across several source lines but folds to one newline-free string, so a block that plainly runs several commands would otherwise slip past the requirement.

Plain single-line `run:` invocations are exempt — they're already a single shell command whose exit status drives the step directly.

Enforced by `scripts/check-run-block-strict.sh`. Wired as the `lint-workflow-security` CI job (member check `run-block-strict`) and as a pre-commit hook.

## fork-guard-release

Every workflow job that holds a guard-required write scope includes a fork-guard `if:` clause containing `github.repository == 'rvenutolo/linPEAS-flake'`.

Guard-required write scopes are any of: `contents: write`, `packages: write`, `id-token: write`, `attestations: write`, `actions: write`. A fork that inherits these workflows can otherwise fire them under its own `GITHUB_TOKEN` (or repo-scoped secrets, if any were configured) — accidentally cutting a release, pushing to the fork's container registry, minting OIDC tokens, or (for `actions: write`) pruning/mutating the canonical repo's Actions cache namespace or cancelling its runs. The repository check pins execution to the canonical repo.

A job that mints a GitHub App installation token (via `actions/create-github-app-token`, or referencing `secrets.BUMP_APP_PRIVATE_KEY`) is likewise privileged despite declaring a read-only `GITHUB_TOKEN`: the App token carries its own write scopes, so the job can commit via the REST contents API, open pull requests, and enable auto-merge — all under the canonical repo's identity. Such a job must carry the same fork guard, otherwise a fork holding the App's private key as a secret could drive those writes against the canonical repo.

GitHub Actions `if:` is job-scoped (no workflow-level syntax), so every guard-required job must carry the guard in its own `if:` expression. Existing `if:` clauses are AND-ed with the repository check.

Enforced by `scripts/check-fork-guard-release.sh`. Wired as the `lint-workflow-security` CI job (member check `fork-guard-release`) and as a pre-commit hook.

## nix-run-pinned

No workflow, script, or shell-fenced documentation runs any `nix` subcommand — `run`, `shell`, `develop`, `build`, or otherwise — against the bare `nixpkgs` flake reference, with or without intervening flags.

At runtime the bare `nixpkgs` resolves through the user's (or runner's) flake registry — not this repo's `flake.lock`. A step that calls `nix run nixpkgs#cosign` therefore pulls whatever nixpkgs commit the runner's registry happens to point at, bypassing the Renovate-pinned `nixpkgs` input in `flake.lock`. A malicious or compromised nixpkgs revision could ship a backdoored tool. The registry lookup is what makes the reference unpinned, so the hazard is identical no matter which subcommand consumes it.

Allowed alternatives:

- `nix shell .#<pkg> --command <pkg> <args>` — uses this repo's own flake outputs, resolved via `flake.lock`. Requires the package to be exposed under `packages.<pkg>` by the flake (see `nix/packages.nix`).
- `nix run .#<pkg> -- <args>` — same.
- `nix run nixpkgs/<rev>#<pkg>` — explicit commit-pin (the lint matches a `nix` command word followed by a bare `nixpkgs#` token, so a `/<rev>` between `nixpkgs` and `#` passes).

`cosign` is exposed under `packages.cosign` so `release-on-bump.yml` and `verify-latest-release.yml` can invoke it via the pinned shape. Future tools follow the same pattern.

Enforced by `scripts/check-nix-run-pinned.sh`. Wired as the `lint-workflow-security` CI job (member check `nix-run-pinned`) and as a pre-commit hook.

## setup-nix composite required

{% raw %}
Every workflow that installs Nix must do so via
`./.github/actions/setup-nix`, passing
`github-token: ${{ secrets.GITHUB_TOKEN }}`. Direct use of any
Nix-installer action from a workflow is forbidden — `cachix/install-nix-action`,
`DeterminateSystems/nix-installer-action`,
`DeterminateSystems/determinate-nix-action`, and
`nixbuild/nix-quick-install-action` are named explicitly, and the lint
also matches unlisted actions of the same family.
{% endraw %}

**Why.** Unauthenticated `api.github.com` tarball fetches are capped
at ~60 requests/hour per source IP. GitHub Actions runner IPs are
shared across many concurrent jobs; under contention the cap is
exhausted and the API returns `HTTP 401 Bad credentials`, which
surfaces from `nix build` / `nix flake` as a flake-input fetch
failure. Passing `access-tokens = github.com=<token>` raises the
ceiling to ~1000/hour per token and eliminates the class.

**Enforcement.** `scripts/check-setup-nix-required.sh`, gated by the
`setup-nix-required` job in `.github/workflows/ci.yml`.
