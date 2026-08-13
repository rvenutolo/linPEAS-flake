# Scripts reference

Auto-generated from in-script `@description` / `@arg` / `@option` /
`@example` annotations by `scripts/refresh-scripts-reference.sh`.
Do not edit between the markers.

<!-- BEGIN scripts-reference -->

{% raw %}

## Check scripts

### scripts/check-actionlint-shellcheck-active.sh

Canary: assert actionlint's embedded shellcheck
integration is wired. Runs the (wrapper-pinned) actionlint
binary against a fixture workflow containing a planted SC2086
violation; fails if the SC2086 code does not appear in output.

If this script fails, the actionlint hook has silently stopped
invoking shellcheck on `run:` blocks. See
docs/actionlint-embedded-linters.md.

Env overrides (test-only):
ACTIONLINT_SMOKE_FIXTURE_OVERRIDE — alternate fixture path

Exits 0 on clean, 1 when the canary fires (shellcheck no longer
reaches `run:` blocks), 2 when the canary could not run at all: the
fixture is missing or actionlint is absent from PATH. A canary that
never ran says nothing about the integration, so it must not borrow
the failure code — that sends a maintainer after a wiring regression
that has not happened.

### scripts/check-allowed-actions-api.sh

Assert the live `actions.permissions.allowed_actions`
API state matches the canonical allowlist documented in
`docs/security/allowed-actions.md`.

### scripts/check-auto-merge-decline-gate.sh

Lint: every workflow run-block that calls `gh pr merge`
with `--auto` must also carry the decline gate (a `gh pr view --json state` query plus a CLOSED|MERGED arm that exits non-zero), so a
maintainer-closed (declined) or already-merged PR is never silently
resurrected by an auto-merging update workflow.

### scripts/check-awk-operand-explicit.sh

Lint: every `awk` invocation in scripts/\*.sh that
carries a file operand must spell that operand
`"$(awk_path "${var}")"`. `awk` reads an operand shaped
`name=value` as a variable assignment rather than a filename; it
then finds no file operand, reads stdin, and exits 0 having scanned
nothing — so a relative path whose first component contains `=`
scores as an empty file instead of failing loud.
`scripts/lib/awk-path.sh`'s `awk_path()` closes that for a wrapped
operand; this lint is the backstop that keeps every future `awk`
call wrapped too, rather than trusting a one-time sweep to hold
forever.

Detection parses each script's shell syntax tree via `shfmt --to-json` (the same mvdan.cc/sh parser `shfmt` and `treefmt`
already run over this repo) rather than matching text: a textual
rule would drift the moment a script's formatting moves an operand
onto another line, inside a multi-line awk program, or next to a
sibling operand. The scan also recognizes `gawk`/`mawk`/`nawk`, an
absolute or relative path ending in one of those basenames (e.g.
`/usr/bin/awk`), a `command`-prefixed invocation, and a
statically-quoted `"awk"`/`'awk'` word — not just the bare `awk`
literal — since a future call site is under no obligation to spell
the command the same way every existing one does.

For every such call, the argument list is walked following awk's
own flags-then-program-then-operands grammar: `-v`, `-F`,
`-f`/`--file`, `--field-separator`, `--assign`, `--source`, `--`,
and their attached forms (`-F'\t'`, `--field-separator=x`,
`-fprog.awk`, `--file=prog.awk`) are all recognized as flags while
no program has been supplied yet. `-f`, `--file`, and `--source`
supply the program text (a repeated one concatenates, which is
legal), so any of them marks the program as already established
without ending flag recognition — a legally-repeated
`-f a.awk -f b.awk` is not misread as two operands; `--field-separator`
and `--assign` keep being read as flags too once a program is
established. `-v`, `-F`, and `--` behave differently once a program
is already established: gawk (measured directly) then reads any of
the three as an ordinary filename rather than as a flag, bare or
attached, so the walk folds a further `-v`/`-F`/`--` back into "this
is an operand" instead of treating it as one. Only the first
non-flag word establishes the inline program (when none of
`-f`/`--file`/`--source` already has); every non-flag word after
that is an operand. `-f`/`--file`'s own value and the program text
itself are excluded from the operand list, since neither was ever a
file operand. Each surviving operand must be exactly one
double-quoted word wrapping a single command substitution that
calls `awk_path` — anything else is a violation.

Not operands, and therefore never reach the walk above: stdin
redirections and here-strings (a redirection attaches to the
enclosing statement, not the command's argument list, so an `awk`
call fed one has zero operand arguments to inspect) and pipeline
input (same — the producer feeds stdin, not an argument).

The total operand count checked across the run is itself asserted
nonzero (unless LINT_ALLOW_EMPTY_SCAN=1): a parser regression that
silently drops every operand from its accounting — e.g. an
attached-flag word reclassified as a no-op instead of as the
operand-bearing word it actually is — would otherwise still print a
clean "0 violations" and exit 0. See the assertion below for why
LINT_ALLOW_EMPTY_SCAN, rather than a dedicated variable, is the
right opt-out.

Honors PATHS_OVERRIDE (newline-separated file list) for fixtures,
and LINT_ALLOW_EMPTY_SCAN=1 to accept a run whose operand tally (or
whose enumerated file count) comes back zero.
Exit 0 clean, 1 on any unwrapped operand, 2 when a required tool is
absent, the scan set could not be enumerated (or came back with a
zero operand tally), a named path does not exist, or a file could
not be parsed as shell.

### scripts/check-bump-script-integrity.sh

Lint: scripts/bump-linpeas.sh retains its three
supply-chain integrity guards — asset-URL prefix, `.digest`
cross-check, and atomic (mktemp + mv) pin write.

### scripts/check-changelog-fresh.sh

Guard that CHANGELOG.md's released sections match a fresh
git-cliff regeneration, so a release that ships without its changelog update
landing — or a manual edit to a released section — is caught rather than
accruing silently.

Only the released portion (from the first `## [<tag>]` header onward) is
compared. The `## Unreleased` section legitimately changes with every merged
commit, so comparing it would force a changelog regen on every PR — the
staleness this guards is released sections lagging the release tags.

A release tag is created before the changelog commit that describes it, so
between the two there is a window in which a released section cannot yet
exist in the committed file. Comparing it there reports staleness that no
commit could fix: main goes red, and because the enforcing CI job is a
required check, every open PR based before the changelog commit is blocked.
A tag is therefore compared only when its commit is an ancestor of the most
recent commit that touched CHANGELOG.md — only when the changelog was written
at a point where that tag already existed. Newer tags are excluded from both
sides of the diff. The condition is history-relative rather than time-based:
a wall-clock grace period would either mask a genuinely dropped changelog or
still flake, depending on how it was tuned.

Blind spot this accepts: only tags predating the last CHANGELOG.md commit are
guarded. A release whose changelog never lands stays unguarded until some
later changelog commit exists, and two releases stacking up inside the window
would exclude both. That is tolerable because a dropped changelog job fails
loudly through the release-on-bump notify path — this check is the backstop,
not the primary signal.

git-cliff is invoked only via the flake-pinned `.#git-cliff` output, per the
nix-run-pinned invariant. Offline and deterministic: git-cliff parses the PR
number from the `(#N)` subject suffix, so no GitHub token is required. Needs
full history + tags (fetch-depth: 0) so every release tag is visible.

Exits 0 when released sections are fresh, 1 when stale, 2 when the check
could not run: nix absent from PATH, the pinned git-cliff exiting non-zero,
or an input file (CHANGELOG.md, cliff.toml) missing. A comparison that never
happened says nothing about whether the committed changelog is fresh, so it
must not borrow the staleness code — that sends a maintainer to regenerate a
changelog that was never the problem. git-cliff's own stderr is passed
through rather than silenced, so the reason is visible in the job log.

Env overrides (test-only):
CHANGELOG_OVERRIDE — committed changelog path (default CHANGELOG.md)
CLIFF_TOML_OVERRIDE — cliff config path (default cliff.toml)
REGEN_OVERRIDE — pre-generated regen file; when set, the git-cliff
call is skipped so the comparison logic can be tested without nix

### scripts/check-changelog-links.sh

Refuse to build if the regenerated changelog contains
duplicate identical PR links or loses the scorecard-count preprocessor.
Validates git-cliff OUTPUT, not the committed CHANGELOG.md formatting.
CHANGELOG.md is generator-owned and excluded from treefmt + markdownlint,
so no other check guards a malformed regeneration.

Offline and deterministic: git-cliff parses the PR number from the `(#N)`
subject suffix, so no GitHub token is required.

git-cliff is invoked only via the flake-pinned `.#git-cliff` output, never
an unpinned `nix run nixpkgs#git-cliff`, per the nix-run-pinned invariant.

Exits 0 when both invariants hold.
Exits 1 on any violation (duplicate links, lost preprocessor).
Exits 2 when the check could not run: nix absent from PATH, cliff.toml
missing, or the pinned git-cliff exiting non-zero. A generator that cannot
run produces no output to validate, so it must not borrow the violation code
— that reads as a malformed regeneration and sends a maintainer after a
cliff.toml assertion that never fired. git-cliff's own stderr is passed
through rather than silenced, so the reason is visible in the job log.

Env overrides (test-only):
CLIFF_TOML_OVERRIDE — path to a fixture cliff.toml instead of
the repo-root cliff.toml

### scripts/check-checkout-persist-credentials.sh

Lint: every `actions/checkout` step in every workflow
sets `with.persist-credentials: false` so the GITHUB_TOKEN is not
left in `.git/config` for subsequent steps to read.

### scripts/check-ci-job-in-summary.sh

Lint: cross-check `.github/workflows/ci.yml` jobs
against `docs/_data/ci-check-categories.yml` in both directions,
with a self-policed EXEMPT list for auxiliary (non-required) jobs.

**Options:**

- `--print-exempt` — print the EXEMPT job list, one name per line, and exit 0 without linting

### scripts/check-cliff-tag-pattern.sh

Refuse to build if cliff.toml's tag_pattern drifts from the
canonical pin-shape regex. Joins the cross-layer parity set enforced in
bump-linpeas.sh, flake.nix, stale-pin-check.yml, release-on-bump.yml,
and gen-dashboard-data.sh.

Exits 0 when tag_pattern exactly matches the canonical value.
Exits 1 on drift (missing key, wrong value).
Exits 2 when the check could not run: yq absent from PATH, or cliff.toml
missing. A config that was never read cannot have drifted, so it must not
borrow the drift code.

Env overrides (test-only):
CLIFF_TOML_OVERRIDE — path to a fixture cliff.toml instead of
the repo-root cliff.toml

### scripts/check-commitlint-config-explicit.sh

Lint: every `wagoid/commitlint-github-action` step pins a
non-empty `configFile:` that resolves to a file on disk, and the merge
ruleset differs from the strict one only by the two zeroed length rules.

### scripts/check-cosign-identity-pinned.sh

Lint: every `cosign verify*` invocation (`verify`,
`verify-blob`, `verify-attestation`, `verify-blob-attestation`) pins
both `--certificate-identity` (or `-regexp`) and
`--certificate-oidc-issuer` so verification is bound to a specific
signer.

### scripts/check-cron-table.sh

Lint: cron schedule table in docs/architecture/ci.md
matches cron triggers in .github/workflows/\*.yml (and \*.yaml) — set
parity, cron string accuracy, and daily arrow-list ordering with
strictly increasing UTC times.

Exit codes:
0 all checks passed
1 drift detected (details printed to stderr)
2 missing input files / parse error / workflow declares >1 cron line

### scripts/check-doc-anchors.sh

Lint: every markdown #anchor link pointing at an
in-tree .md (or same-file fragment) must match a heading slug in
the target file.

### scripts/check-doc-cron-restatement.sh

Lint: ban restating literal workflow cron times in docs.
A line that names a workflow (backticked bare name `NAME` or a
`NAME.yml`/`NAME.yaml` token) AND carries a clock time (HH:MM) restates the
single source of truth, the schedule table in docs/architecture/ci.md.
Such lines must live only in that table; this lint flags them
everywhere else (README.md + docs/\*\*, excluding ci.md itself).

Exit codes:
0 no restatements found
1 restatement(s) found (details printed to stderr)
2 the check could not run: missing/empty .github/workflows directory,
or a producer that lists or reads the doc files failed

### scripts/check-dockerhub-token-scope-split.sh

Lint: enforce the DOCKERHUB_TOKEN RW/DELETE scope split.
The delete-scoped PAT (secrets.DOCKERHUB_TOKEN_DELETE) is consumed only
by dockerhub-sync.yml (peter-evans/dockerhub-description needs Delete
scope to PATCH repo metadata; a Read/Write-only PAT returns 403). The
write-scoped PAT (secrets.DOCKERHUB_TOKEN_RW) is consumed only by
release-on-bump.yml — never by the anonymous/read-only
verify-latest-release.yml. The delete-capable token must never leak into
workflows that only push images, and no unsuffixed secrets.DOCKERHUB_TOKEN
may exist — only \_RW and \_DELETE are authoritative.

Honors WORKFLOWS_DIR_OVERRIDE (defaults to .github/workflows) so the test
harness can point at a temp dir, and LINT_ALLOW_EMPTY_SCAN=1 to accept a
workflows dir holding no YAML. Exits 0 if the split holds, 1 on a
violation, 2 when the workflows dir is not there to read, holds no
workflow to read, or holds one that could not be read.

### scripts/check-egress-allowlist.sh

Lint: every job's harden-runner `allowed-endpoints` list
carries the hosts its tool inventory actually reaches, carries the ghcr
blob host alongside ghcr.io, carries a complete Docker Hub pull host set
(and the push host too, if it logs in or pushes) if it carries any Docker
Hub registry host at all, carries a complete sigstore host set if it
carries any sigstore host at all, and carries no denylisted host.

### scripts/check-enumerate-helper-required.sh

Lint: every filesystem enumeration in a repo script runs
through `enumerate_into` (scripts/lib/enumerate.sh). A producer —
`find`, `git ls-files`, `git ls-tree` — may appear only as an argument
to the helper, inside a function the helper is handed by name, or
behind an inline `# enumerate-exempt: <rationale>` marker.

The property being protected is scan breadth, not producer status. A
producer that fails is the easy half; the hard half is a producer that
succeeds and enumerates nothing: `GIT_INDEX_FILE=/nonexistent git ls-files` exits 0 and prints not one path, which every status check in
the world reads as a clean tree. A lint that scans an empty set finds
no violations and exits 0 — off, and green. So breadth has to be
asserted rather than inferred, and `enumerate_into` is where that
assertion lives: routing every enumeration through it makes the
assertion structural instead of something each call site has to
remember.

That is what makes this rule decidable in one pass. Associating an
enumeration with a cardinality test written an arbitrary distance
later is not something a textual rule can do; asking whether a
producer is an argument to the helper is local to one call expression.

Detection parses each script's syntax tree via `shfmt --to-json` (the
mvdan.cc/sh parser `shfmt` and `treefmt` already run over this repo)
rather than matching text, because three shapes here name the banned
commands without running them and a textual rule would need a
special case for each: this file's own prose, the label string every
compliant call site passes (`enumerate_into paths 'git ls-files' git ls-files -z …`), and heredocs documenting the idiom. None of them is a
command node, so none of them is a hit.

A `git` invocation's subcommand is found by walking past the global
flags (`-C <dir>`, `-c <k>=<v>`, `--git-dir=…`) rather than by reading
the word right after `git`: the one hand-rolled enumeration this lint
was written against spelled it `git -C "${ROOT}" ls-files`.

The count of producer calls classified is itself asserted nonzero
(unless LINT_ALLOW_EMPTY_SCAN=1). A grammar that silently recognized
no producers would report "0 violations" and exit 0 — the same clean
line a genuinely producer-free tree prints — leaving this gate off
while green, which is the exact failure it exists to prevent one level
down.

Honors PATHS_OVERRIDE (newline-separated file list) for fixtures, and
LINT_ALLOW_EMPTY_SCAN=1 to accept a run whose producer tally (or whose
enumerated file count) comes back zero.
Exit 0 clean, 1 on a producer outside the helper or an exemption
marker with no rationale, 2 when a required tool is absent, the scan
set could not be enumerated (or classified nothing), a named path does
not exist, or a file could not be parsed as shell.

### scripts/check-ephemeral-refs.sh

Lint: every Markdown file, shell script and Nix source in
the repo must carry no ephemeral references — PR/issue refs, prose
dates, planning/review-pass labels, or literal `.claude/` paths.
Markdown is read as prose; shell is read as comments only, lifted from
the `shfmt` syntax tree; Nix is read as full-line comments only.
Default mode blocks (exit 1); --advisory mode
suppresses findings, not defects: it warns on fuzzy causal-history
phrases and exits 0 on those, but a could-not-run (unterminated
fence/block, unparsable shell, a scan covering shell or Nix that
extracted no comments, failed source enumeration) still exits
non-zero the same as the default pass.

**Options:**

- `--advisory` — suppress findings, not defects: warn on fuzzy causal-history phrases and exit 0 for those, but still exit 1 on an unterminated fence/generated block and 2 on a failed source enumeration, an unparsable shell source, or a shell/Nix scan that extracted no comments

### scripts/check-flake-lock-provenance.sh

Lint: a bot `flake.lock` bump may only move
`rev`/`narHash`/`lastModified`. Fails when a top-level input is
added, removed, or repointed, or when any node present in both base
and head has its source identity (owner/repo/type/url/ref/flake/...)
changed. Gates the auto-merged weekly flake.lock update so a
source-level repoint of an input cannot slip into the build/dev
closure unreviewed.

### scripts/check-flake-systems-eval.sh

Assert every system declared in `flake.lib.systems`
evaluates, forcing each package's derivation (not just the attribute
names) so a package whose value throws is caught. Fails naming the
offending system + the real nix error, so a platform drop in a nixpkgs
bump is diagnosable at a glance.

**Options:**

- `--flake` — <dir> flake to check (default: repo root)

### scripts/check-fork-guard-release.sh

Lint: every workflow job holding a guard-required write
scope (contents/packages/id-token/attestations/actions: write) carries
a fork-guard `if:` pinning execution to the canonical repo.

### scripts/check-freshness-hook-watches-modules.sh

Lint: every pre-commit hook whose entry runs a generator
that evaluates `devTooling.<system>.<attr>` names, in its `files`
regex, every nix module that attribute is defined or transposed by.

### scripts/check-gh-api-version-header.sh

Lint: every `gh api` invocation and `api.github.com`
request in scripts/\*.sh passes an explicit
`X-GitHub-Api-Version: <date>` header.

### scripts/check-gh-attestation-repo.sh

Lint: every `gh attestation verify` invocation across
workflows, composite actions, scripts, nix modules, the justfile, and
docs passes `--repo rvenutolo/linPEAS-flake` so verification is bound
to this repository.

### scripts/check-guard-exit-code.sh

Lint: no script anywhere under `scripts/` may exit 1 out
of a guard whose test is only an availability check. The exit codes separate what the
operator has to do about a run: 2 means the check could not run (a
required tool is absent, an input is missing, unreadable or
malformed), 1 means it ran and found a violation, 0 means clean. An
absent tool reported as 1 sends the operator hunting for drift in
content the check never read, and a hook or job that reports both the
same way makes a broken environment indistinguishable from a broken
repo.

A hit is a conditional whose test is PURELY an availability predicate
and whose branch body exits 1:

if ! command -v X if ! require_tool X
if \[[ ! -f|-r|-e|-d|-s P ]\] \[[ -f P ]\] || { ... }

Matching is branch-scoped rather than proximity-based: the branch body
is walked from its opening keyword to the matching `fi` or closing
brace, so an exit that merely sits a few lines below an availability
test is not attributed to it. Many checks here read a marker or a
field out of a file that exists and report its absence as the finding
— those exits belong to the search that came back empty, not to the
guard above them, and a line-window scan attributes exactly those to the wrong guard.

A test that mixes an availability predicate with another predicate
under `||` is not a hit: that branch is reachable without the input
being absent, so absence there is half of a content verdict rather
than a could-not-run.

Escape hatch: `# exit-code-exempt: <rationale>` on the exit line, for
a guard whose missing input genuinely IS the finding. The marker has
to open the comment, so prose naming it exempts nothing, and the
rationale has to be non-empty. A clean run prints the exemption count,
so the exempt set is stated rather than open-ended.

The scan recurses. The shared libraries under `scripts/lib/` decide
which exit code their callers report — `enumerate_into` is where a
could-not-run enumeration becomes exit 2 for every lint that uses it —
so a scan stopping at the top level would vouch for the code that
settles the very convention this lint enforces.

Honors SCRIPTS_DIR_OVERRIDE (default: scripts) for fixtures.
Exit 0 clean, 1 on any hit, 2 on operational error.

### scripts/check-harden-runner-block.sh

Lint: every step-security/harden-runner step uses
egress-policy: block with a non-empty allowed-endpoints list,
preventing network-level egress to unlisted hosts.

### scripts/check-harden-runner-first.sh

Lint: every job in .github/workflows/\*.yml begins
with `step-security/harden-runner@<sha>` as its first step, so the
eBPF monitor installs before any I/O.

### scripts/check-job-timeout-minutes.sh

Lint: every job under .github/workflows/\*.yml
declares an explicit `timeout-minutes`, bounding blast radius
from hung jobs. Reusable-workflow jobs are exempt.

### scripts/check-jsonschema.sh

Validate repo config files (renovate.json, workflow
YAML, composite-action YAML, .markdownlint.json) against pinned
JSON Schemas using `check-jsonschema`.

### scripts/check-lint-shell-tools.sh

Assert every tool the batched `.#lint`-hosted invariant-lint
groups (lint-workflow-security, lint-script-hygiene) rely on is present on
PATH. These groups run inside devShells.lint in CI; this guard turns a
dropped tool into a named failure instead of a cryptic mid-check error.
Keep EXPECTED in sync with the lintTools list in nix/devshell-lint.nix.

### scripts/check-manifest-digest-pinned.sh

Lint: every multi-arch manifest-creating docker command
references its SOURCE images by immutable digest, never by a mutable
tag.

### scripts/check-manifest-hook-watches-nix.sh

Lint: every pre-commit hook that reaches the flake hook
manifest — by running a manifest-reading script, or by building a flake
attribute a manifest-reading module assigns — includes `nix/hooks` in
its `files` regex.

### scripts/check-min-permissions.sh

Strict least-privilege lint for GitHub Actions
GITHUB_TOKEN scopes: top-level `permissions: {}` and an explicit
per-job `permissions:` block in every workflow.

### scripts/check-nix-run-pinned.sh

Lint: ban any `nix` invocation against the bare
`nixpkgs` registry ref across workflows, scripts, and shell-fenced
markdown. Allowed alternatives use the repo's own flake or an
explicit commit pin.

### scripts/check-no-opaque-procsub.sh

Lint: no script anywhere under `scripts/` feeds a
redirection from a process substitution. A substitution runs in its own subshell, so `set -Eeuo pipefail` only ever sees the status of the command the redirection
feeds — never the producer's. A failed producer hands the consumer
empty output to score as data: either a clean pass that flags nothing
(fail-open) or a substantive violation the input never showed (a
tooling fault misdiagnosed as drift). That property holds for whatever
the producer is, so the rule does not ask: every `< <(...)` is a hit,
with no exemption.

`diff <(...) <(...)` stays legal: diff consumes both substitutions as
file arguments and its own exit status is what the caller acts on, so
no status is lost.

Use the capture-into-variable idiom (or a temp file for NUL-delimited
output) so a producer failure aborts loudly.

The scan recurses. A shared library under `scripts/lib/` runs inside
whichever caller sources it, so a lost producer status there is lost
for every script in the tree at once — the widest blast radius the
banned shape has, and the one a top-level-only glob never reads.

Honors SCRIPTS_DIR_OVERRIDE (default: scripts) for fixtures.
Exit 0 clean, 1 on any hit, 2 on operational error.

### scripts/check-orphan-invariants.sh

Lint: docs/invariant-index.md and docs/\*\*/\*.md stay
in lockstep — every index pointer resolves to a real file, and
every non-EXEMPT docs file has an index entry.

### scripts/check-patch-tag-pins.sh

Lint: every SHA-pinned `uses:` in workflow / composite
action files carries an exact patch-tag comment — present, and shaped
as `# v<major>.<minor>[.<patch>]` with at least two numeric components
(e.g. `# v1.2.3`). A missing comment, a comment naming no version
(e.g. `# main`), and a floating major-tag comment (e.g. `# v1`) are
all violations. The only escape is an inline
`# patch-tag-exception: <reason>` marker on the same line.

### scripts/check-path-hygiene.sh

Lint: no path tracked in this repo, nor any untracked
path a commit is about to introduce, may contain a byte in the
0x01-0x1F control range or DEL (0x7F). A newline defeats every
line-oriented path handoff in this repo's own tooling, and a tab
corrupts the tab-separated inventories those handoffs produce just as
surely, so both stay in scope alongside the rest of the control range.

### scripts/check-permission-scopes.sh

Per-job GITHUB_TOKEN write-scope allowlist lint for
GitHub Actions. Fails when a job grants a write scope absent from
.github/permission-scopes.yml, or when an allowlist entry is stale.

### scripts/check-pin-diff-isolated.sh

Lint: exactly one script under `scripts/` writes to
`linpeas-pin.json` (bump-linpeas.sh), so the
`release-on-bump.yml` path-filter trigger contract is
self-enforcing.

### scripts/check-pin-digest-provenance.sh

Lint: a pin digest may not move under an unchanged
version label. Diffs action pins (`uses: <path>@<sha> # <version>`)
in workflows/composite actions and the octoscan container digest
pair against the base ref; a changed SHA/digest whose version
comment did not change is a repointed released tag (the
digest-repoint supply-chain class) and fails. Floating-major pins
(`# vN`) legitimately retarget across patch releases, so instead of
a hard fail their new commit must be reachable from the upstream
default branch — a force-pushed dangling commit fails.

### scripts/check-pre-commit-hooks-sha-parity.sh

Lint: the SHA embedded in `flake.nix`'s
`pre-commit-hooks` input URL matches `flake.lock`'s pinned
`pre-commit-hooks.locked.rev`.

### scripts/check-protect-main.sh

Lint: the live `protect-main` branch ruleset matches
the desired posture, the in-tree mirror at
`.github/rulesets/protect-main.json`, and the `## Required contexts`
table in `docs/security/required-checks.md`.

### scripts/check-pr-workflows-no-secrets.sh

Lint: no workflow triggered by `pull_request` /
`pull_request_target` references any `secrets.*` other than
`secrets.GITHUB_TOKEN`.

### scripts/check-pull-request-target-absent.sh

Lint: hard-fail if any workflow under
.github/workflows/\*.yml uses the `pull_request_target` trigger,
foreclosing the canonical Actions privilege-escalation footgun.

### scripts/check-ratchet-pin-audit.sh

Lint: the ratchet-pin-audit workflow keeps its
hardened shape — empty top-level permissions, harden-runner first,
typed reason tokens in the notify body, ratchet in the
nix/devshell.nix devShell — so future edits cannot silently weaken it.

### scripts/check-renovate-config-validator.sh

Validate renovate.json against the upstream Renovate
config schema using `renovate-config-validator --strict --no-global`.
Catches typoed keys, wrong-type values, and unknown options that
per-tool linters miss. Complements scripts/check-renovate-invariants.sh,
which asserts repo-policy invariants on top of a valid schema.

Honors RENOVATE_JSON_OVERRIDE for fixture testing.
Exits 0 on a valid config, 1 on any validation error, 2 when the check
cannot run — the config file is absent, or the validator itself is not
on PATH. Neither says anything about the config's validity, so neither
may borrow the rejection code.

### scripts/check-renovate-invariants.sh

Lint: renovate.json carries the security-critical
invariants — pinGitHubActionDigests, minimumReleaseAge, no top-level
automerge, per-manager pinDigests for github-actions.

### scripts/check-renovate-markers-matched.sh

Lint: every `# renovate: datasource=…` marker in the tree is
live — some renovate.json customManager scopes the marker's file (a
managerFilePattern matches the path) and matches a line in it (a matchString
matches). A customManager that matches none of its declarations freezes the
dependency silently outside automation coverage; this check fails CI before
that can happen.

Coverage is file-level, not marker-line-level: marker styles differ (inline,
where value + `# renovate:` share a line; and above, where the comment sits
on its own line and the matched value is on the next). Asserting the marker's
file is consumed by a live manager handles both without a line-adjacency
heuristic.

Honors RENOVATE_JSON_OVERRIDE (config path) and SCAN_ROOT (tree root) for
fixture testing, and LINT_ALLOW_EMPTY_SCAN=1 to accept an empty scan set.
Exits 0 when every marker is live, 1 on any dead marker, 2 on a tooling
error — the config file is absent, the file enumeration failed or came
back empty, or jq cannot read a customManager's declarations — so no
verdict about the markers is available and reporting one would blame a
marker for a config-shape problem.

### scripts/check-required-checks-no-paths.sh

Lint: no workflow listed in
docs/security/required-checks.md declares `paths:` or
`paths-ignore:` under `on.pull_request:` — avoiding the auto-merge
path-filter skip trap.

### scripts/check-run-block-pyflakes-required.sh

Guard: fail if any GitHub Actions `run:` block
invokes python (python/python3/pip/pip3) while pyflakes is not
wired into the actionlint hook. Today no python run: exists,
so this is a passive gate. The day someone adds a python run:,
this fails with a pointer to the runbook describing how to
wire pyflakes.

Scope: .github/workflows/\*.{yml,yaml} and
.github/actions/\*\*/action.{yml,yaml}

Env overrides (test-only):
PYFLAKES_GUARD_SCAN_ROOT_OVERRIDE — alternate directory tree
containing workflow/action YAML files (overrides the default
repo-root .github/ scan).
LINT_ALLOW_EMPTY_SCAN — set to 1 to accept an empty scan set.

Exits 0 on clean, 1 if any python invocation found, 2 when the scan set
could not be enumerated or came back empty.

### scripts/check-run-block-strict.sh

Lint: every block-scalar or newline-carrying `run:`
block under `.github/workflows/*.yml` (or `.yaml`) and
`.github/actions/**/action.yml` (or `.yaml`) starts with
`set -Eeuo pipefail` as its first non-blank, non-comment line.

### scripts/check-scorecard-threshold.sh

Reads OSSF Scorecard JSON on stdin; exits 1 if any
check scored below 10. Prints offender names + scores to stderr.

### scripts/check-script-has-test.sh

Lint: every `scripts/check-*.sh` has a matching
`tests/check-*.test.sh` and vice versa, modulo an explicit EXEMPT
list.

### scripts/check-script-shebang-pipefail.sh

Lint: every executable script under `scripts/` starts
with `#!/usr/bin/env bash` (exact first line) and contains
`set -Eeuo pipefail` somewhere in the file; every sourced library
under `scripts/lib/` satisfies the inverse.

### scripts/check-settings-posture.sh

Lint: every gh-API-verifiable row in
`docs/security/settings-posture.md` matches the live repository
configuration. Manual-UI rows are out of scope.

### scripts/check-setup-nix-required.sh

Lint: every workflow installing Nix goes through the
composite `./.github/actions/setup-nix` — no vendor Nix-installer
action directly — and passes
`github-token: ${{ secrets.GITHUB_TOKEN }}`.

### scripts/check-tag-protection.sh

Lint: the live `release-tag-protection` ruleset
matches the desired posture (tag target, active enforcement, ref
include pattern, required rules).

### scripts/check-test-reachable.sh

Lint: every tests/\*.test.sh harness is executed by some runner.
check-script-has-test guarantees a test FILE exists for each script; it does
not guarantee the test ever RUNS. A harness reachable by no runner is a
coverage no-op — the regressions it would catch pass green while the pairing
guard stays satisfied. This asserts every harness is reachable via one of
four runners:

1. the HARNESSES array in scripts/run-harness-group.sh (harness-group job),
1. the tests/refresh-\*.test.sh glob in scripts/run-doc-freshness.sh,
1. a .github/lint-groups.yml member -> tests/check-<name>.test.sh
    (executed by scripts/run-lint-group.sh), or
1. a direct `tests/<x>.test.sh` invocation in a .github/workflows/\*.yml.

Overridable dirs/paths let the paired test harness point at fixtures. Exits
0 if every harness is reachable, 1 otherwise.

### scripts/check-upload-artifact-strict.sh

Lint: every `actions/upload-artifact` step in every
workflow under `.github/workflows/*.yml` sets
`with.if-no-files-found: error` so empty-glob bugs hard-fail.

### scripts/check-uses-sha-pinned.sh

Lint: every `uses:` in `.github/workflows/*.yml` (or
`.yaml`) and `.github/actions/**/action.yml` (or `.yaml`) ends with a
full 40-hex SHA, or is a local path-relative reference.

### scripts/check-verify-reason-ladder.sh

Lint: the `attribute failure reason` step of
`verify-latest-release.yml` covers every id-carrying step of the
`verify` job, reads every env var it declares, documents every reason
token it emits, and walks the ladder in step-execution order.

### scripts/check-workflow-concurrency.sh

Lint: every workflow under .github/workflows/\*.yml
declares a top-level `concurrency:` block with a non-empty
`group:` string.

### scripts/check-workflow-on-branches.sh

Lint: every workflow declaring `on.pull_request:` or
`on.push:` explicitly sets `branches: [main]` under that trigger
— no wildcards, no implicit all-branches.

## Refresh scripts

### scripts/refresh-ci-dag.sh

Regenerate the ci-dag managed block in
docs/architecture/ci-dag.md from .github/workflows/ci.yml plus the
docs/\_data/ci-check-categories.yml map.

**Options:**

- `--check` — exit 1 if the doc would change; exit 2 if an input file

### scripts/refresh-ci-summary.sh

Regenerate the ci-summary managed block in README.md
from required-checks.md plus the ci-check-categories.yml map.

**Options:**

- `--check` — exit 1 if README.md would change; exit 2 if an input

### scripts/refresh-enforcement-matrix.sh

Regenerate docs/security/enforcement-matrix.md from
the inline enforcer annotations on every bullet of
docs/invariant-index.md, with bidirectional orphan checks.

**Options:**

- `--check` — exit 1 if the matrix would change; do not mutate the working tree

### scripts/refresh-flake-show.sh

Regenerate the flake-show managed block in
docs/reference/flake-outputs.md from `nix flake show --all-systems`.

**Options:**

- `--check` — exit 1 if the doc would change; exit 2 if the check

### scripts/refresh-just-recipes.sh

Regenerate the just-recipes managed block in
README.md and docs/reference/just-recipes.md from the current
`just` recipe list.

**Options:**

- `--check` — exit 1 if either doc would change; exit 2 if either doc

### scripts/refresh-precommit-table.sh

Regenerate the precommit-table managed block in
docs/development/git.md from the current pre-commit hook manifest
in the flake.

**Options:**

- `--check` — exit 1 if the doc would change; exit 2 if the doc is

### scripts/refresh-scripts-reference.sh

Regenerate the scripts-reference managed block in
docs/reference/scripts.md from in-script shdoc-style annotations
parsed by scripts/\_script_docs.awk. Groups entries by basename
prefix into Check / Refresh / Other sections.

**Options:**

- `--check` — exit 1 if drift; exit 2 if the doc or the awk parser is

### scripts/refresh-treefmt-config.sh

Regenerate the treefmt-config managed block in
docs/reference/treefmt-config.md from the enabled-formatter manifest
exposed by `nix/treefmt-config.nix` as `devTooling.<system>.treefmtConfig`.

**Options:**

- `--check` — exit 1 if the doc would change; exit 2 if the check

## Other

### scripts/apply-patch-tag-pin-rewrite.sh

Apply the patch-tag pin comment rewrite recorded in an
inventory TSV produced by scripts/inventory-action-pin-tags.sh.
Refuses to run if any recorded line content no longer matches the
inventory (stale inventory protection) — aborts before mutating any
file so the rewrite is all-or-nothing across the tree.

OK rows have `target_comment` populated and are applied in place.
NO_PATCH_TAG rows are skipped with a stderr warning.
Any API_FAILURE row aborts the run before any mutation.

Literal substring splicing via awk index/substr — no regex pitfalls
on semver dots or path slashes.

Default inventory path: ${TMPDIR:-/tmp}/action-pin-inventory.tsv
Override with --inventory PATH.

Honors LINT_ALLOW_EMPTY_SCAN=1 to accept an inventory carrying no rows.

Exits 0 on a completed run, 1 when the inventory is rejected (API
failure row, unknown status, stale line content), 2 when a file the run
needs is not there to read — an unknown argument, an inventory file
that is absent or unreadable, an inventory with no rows in it, or a
recorded target file that is absent. Nothing was inspected in those
cases, so the rejection code would misreport an unread file as a
rejected one; a stale line, by contrast, is read before it is judged.

### scripts/bump-linpeas.sh

Bump linpeas-pin.json to the latest peass-ng/PEASS-ng release.

### scripts/classify-backfill-image-mode.sh

Classify whether a release-on-bump `backfill-tag` run
should exercise the per-arch image pipeline. Given the presence
(`present`/`absent`) of the four per-arch container tags in the
order amd64@ghcr amd64@hub arm64@ghcr arm64@hub, print `full` when
all four exist, `none` when all four are absent, and fail on any
partial mix. Pure and side-effect free so the decision is
unit-testable without contacting a registry.

### scripts/classify-pin-ref.sh

Classify one SHA-pinned action ref for
ratchet-pin-audit: given the pinned SHA and the tag's resolved git
objects, print `current`, `drift`, or `skip-floating-major`. Pure
and side-effect free so the drift decision — including the
attack-detection branch — is unit-testable without contacting the
GitHub API.

### scripts/compare-repro.sh

Compare two reproducibility-build hash JSON files.
Emits a markdown table to GITHUB_STEP_SUMMARY (or stdout if unset)
and exits 0 on full match, 1 on any divergence, 2 on bad input. Bad
input includes an absent, null, or malformed hash field: two builds
that both measured nothing are not a match.

### scripts/docs-audit-pressure.sh

Report docs-audit drift pressure over a rolling window:
how many commits touched CI structure (.github/workflows, scripts,
.github/lint-groups.yml), and which job ids / lint-group members were
added or removed. Emits a Markdown body for the monthly docs-audit
reminder issue, terminated by a machine-readable PRESSURE=<n> line.

Freshness gates validate only generated blocks; hand-written prose about
CI drifts silently. CI churn is the best cheap proxy for that drift, so it
decides whether a semantic audit is worth running this month.

Body contents are restricted to integers and shape-validated identifiers
parsed from YAML — never commit subjects or other free text, which would
render as arbitrary markdown in the resulting issue.

Honors LINT_ALLOW_EMPTY_SCAN=1 to accept a ref whose workflows dir holds
no YAML.

Exit codes:
0 success (body on stdout, PRESSURE=<n> as the final line)
2 missing inputs / parse error / nothing enumerated to measure

### scripts/gen-dashboard-data.sh

Generate docs/\_data/dashboard.yml for the MkDocs site
by aggregating pin metadata and live GitHub REST API data.

### scripts/inventory-action-pin-tags.sh

Enumerate every SHA-pinned `uses:` in
.github/workflows/*.yml|*.yaml and .github/actions/\*\*/action.yml
(or action.yaml), resolve each pinned SHA to its exact patch tag via
`gh api .../tags`, and emit a TSV mapping pin -> patch tag for
downstream rewrite tooling.

### scripts/octoscan-scan.sh

Run synacktiv/octoscan against `.github/workflows`
via the pinned ghcr container image. Single source of truth for
the image digest, the version label tracked by Renovate, the
noise-suppression flags, and the exit-code mapping shared by the
CI workflow and the pre-commit hook.

Usage:
scripts/octoscan-scan.sh # text output to stdout
scripts/octoscan-scan.sh --sarif <path> # SARIF output to <path>

Exit codes:
0 — scan clean
1 — findings present, OR the scanner ran and errored (image pull
failure, scanner internal error). The caller must distinguish
via the `has-finding` line printed to stdout
(`has-finding=true|false`) — same contract the CI workflow
already exposes via `$GITHUB_OUTPUT`.
2 — the scan could not start: a tool it needs is absent, so no
workflow file was read. Still fails the hook and the job; only
the diagnosis differs, and it now matches the `infra-failure`
classification this script already prints for the case.

Per-file iteration: octoscan v0.1.7 directory-target mode silently
returns exit 0 with empty SARIF even when a single-file invocation
against the same workflow flags a finding. Loop over each workflow
yaml, tracking "any file errored" separately from "any file has a
finding" (an error must not be masked by another file's finding), and
merge per-file SARIF `runs[0].results` into a single SARIF document for
upload only when no file errored.

Suppressions (CLI flags — `--config-file` is documented but
`paths.<glob>.ignore` is a no-op in v0.1.7):
--disable-rules local-action : repo intentionally uses
`./.github/actions/*` composite actions (e.g.
notify-workflow-result, setup-nix); every reference is a
false positive.
--disable-rules dangerous-write : every `>> "$GITHUB_OUTPUT"`
and `>> "$GITHUB_ENV"` is flagged regardless of input
trust; the rule has no notion of which writes carry
attacker-controlled data, so it is unworkably noisy here.
--ignore '(needs|steps).\*\*.outputs.\*\*' : `expression-injection`
fires on every workflow-internal `${{ needs.X.outputs.Y }}`
/ `${{ steps.X.outputs.Y }}` reference; those carry data
set by other jobs/steps in the same workflow, not external
input.
--ignore "actions/checkout' with a custom ref" : same regex
covers the renovate-flake-lock-refresh workflow's
`actions/checkout` with `ref:` set to a bot-controlled
branch — the ref source is internal, not attacker-supplied.

Renovate manages OCTOSCAN_DIGEST + OCTOSCAN_VERSION in lockstep
(renovate.json customManager scoped to this file).

### scripts/run-doc-freshness.sh

Run every doc-freshness regenerate-and-diff harness
(tests/refresh-\*.test.sh) in one devShell, printing a per-generator
pass/fail summary table to stdout and $GITHUB_STEP_SUMMARY. Runs all
harnesses even if one fails; exits 1 if any failed, 2 if none found.

### scripts/run-harness-group.sh

Run every setup-tax failure-mode harness in one devShell,
printing a per-harness pass/fail summary table to stdout and
$GITHUB_STEP_SUMMARY. Runs all harnesses even if one fails; exits 1
if any failed.

### scripts/run-lint-group.sh

Run every invariant-lint check in a named group from
.github/lint-groups.yml inside one devShell, printing a per-check
pass/fail summary table to stdout and $GITHUB_STEP_SUMMARY. Runs all
checks even if one fails; exits 1 if any failed, 2 on config error.

{% endraw %}

<!-- END scripts-reference -->
