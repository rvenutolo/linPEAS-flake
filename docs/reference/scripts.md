# Scripts reference

Auto-generated from in-script `@description` / `@arg` / `@option` /
`@example` / `@exitcode` / `@stdout` annotations by `scripts/refresh-scripts-reference.sh` (run
via `just show-scripts`).
`scripts/*.sh` entry points render their header annotations; the
sourced libraries under `scripts/lib/` render one entry per library —
its file header, then one sub-entry per annotated function — in the
Libraries section. The `scripts/*.awk` parsers are not rendered here;
they are documented from the entry points that invoke them.
Do not edit between the markers.

<!-- BEGIN scripts-reference -->

{% raw %}

## Check scripts

### scripts/check-actionlint-pyflakes-active.sh

Canary: assert actionlint's embedded pyflakes
integration is wired. Runs the (wrapper-pinned) actionlint
binary against a fixture workflow containing a planted unused
import; fails if a pyflakes finding does not appear in output.
pyflakes emits no numeric codes of its own (F401 and friends are
flake8's numbering), so the assertion is on actionlint's own
`[pyflakes]` linter tag, which is present exactly when pyflakes ran
and reported.

If this script fails, the actionlint hook has silently stopped
invoking pyflakes on python `run:` blocks. See
docs/actionlint-embedded-linters.md.

Env overrides (test-only):
ACTIONLINT_PYFLAKES_FIXTURE_OVERRIDE — alternate fixture path

Exits 0 on clean, 1 when the canary fires (pyflakes no longer
reaches python `run:` blocks), 2 when the canary could not run at all:
the fixture is missing or actionlint is absent from PATH. A canary that
never ran says nothing about the integration, so it must not borrow
the failure code — that sends a maintainer after a wiring regression
that has not happened.

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

Lint: every `awk` invocation in a script under
`scripts/` that carries a file operand must spell that operand
`"$(awk_path "${var}")"`. `awk` reads an operand shaped
`name=value` as a variable assignment rather than a filename; it
scans the whole tree: the `scripts/*.sh` git pathspec crosses `/`,
so the sourced libraries under `scripts/lib/` are in scope too. It
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
cross-check, and atomic (make_temp + mv) pin write.

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
canonical pin-shape regex. One member of the cross-layer parity set;
docs/architecture/auto-update.md lists every file that carries the
regex, derived from the tree rather than restated here.

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

Lint: ban restating a workflow's cron schedule in docs.
A line that names a workflow (backticked bare name `NAME` or a
`NAME.yml`/`NAME.yaml` token) AND carries either a clock time (HH:MM) or a
numeric cadence (`every N minutes/hours/days`) restates the single source
of truth, the schedule table in docs/architecture/ci.md. Such lines must
live only in that table; this lint flags them everywhere else
(README.md + docs/\*\*, excluding ci.md itself).

Bare `daily`, `weekly`, and `Friday` are deliberately out of reach: the
sanctioned form is prose like "runs on a daily cron (see the schedule
table)", and a pattern that flagged those would report the very phrasing
this lint exists to encourage.

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

The same split binds the manual recovery snippets in the docs. A
shell-fenced Markdown block that performs a tag delete
(`--request DELETE` / `-X DELETE`) against Docker Hub must name
DOCKERHUB_TOKEN_DELETE and must not name DOCKERHUB_TOKEN_RW: the
write-scoped PAT returns 401 on a tag delete, so a snippet pasting it
hands the operator a failure that reads like a credential problem.
A fence counts as a Docker Hub delete when it does a DELETE and either
addresses hub.docker.com or names a DOCKERHUB_TOKEN — a DELETE against
some other API is not this rule's business, and scoping on the host
alone would exempt a snippet that spells the host through a variable.
Token names are matched over the whole fence, not the delete line: a
real snippet assigns its credential many lines above the request.

Honors WORKFLOWS_DIR_OVERRIDE (defaults to .github/workflows) so the test
harness can point at a temp dir, PATHS_OVERRIDE (newline-separated file
list) for the Markdown scan set, and LINT_ALLOW_EMPTY_SCAN=1 to accept a
workflows dir holding no YAML or an empty Markdown scan set. Exits 0 if
the split holds, 1 on a violation, 2 when the workflows dir is not there
to read, holds no workflow to read, holds one that could not be read, or
the Markdown scan set could not be enumerated.

### scripts/check-egress-allowlist.sh

Lint: every job's harden-runner `allowed-endpoints` list
carries the hosts its tool inventory actually reaches, carries the ghcr
blob host alongside ghcr.io, carries a complete Docker Hub pull host set
(and the push host too, if it logs in or pushes) if it carries any Docker
Hub registry host at all, carries a complete sigstore host set if it
carries any sigstore host at all, matches the declared notify egress set
if the job runs the notify-workflow-result composite, and carries no
denylisted host.

### scripts/check-enumerate-helper-required.sh

Lint: every filesystem scan in a repo script or test
harness asserts its own breadth. The scan set is `scripts/*.sh` plus
`tests/*.test.sh`, less `tests/fixtures/` — a tree whose files exist to
be violations of this lint, driven through PATHS_OVERRIDE by the
harness that asserts the diagnostics they produce.
An enumeration runs through `enumerate_into`
(scripts/lib/enumerate.sh) — a producer (`find`, `git ls-files`, `git ls-tree`) may appear only as an argument to the helper, inside a
function the helper is handed by name, or behind an inline
`# enumerate-exempt: <rationale>` marker. Copying a producer word to a
variable is banned at that same assignment, since the use site's
command word is then a value no single pass can resolve; the array
form is read only at element 0, its command head, so a producer word
planted at a non-head index and later spliced into command position by
index arithmetic still evades. A glob-driven scan fills its
array through `glob_into` — neither a `for` loop at its own head nor an
array assignment in its element list may expand a pattern, whether the
metacharacter is written bare in the word itself, sits one level in
among the Lit parts of the word any expansion there carries (its
alternate, default, or pattern-operand word alike), or is
held in a variable this same file assigns a pattern and read unquoted
at either place, unless an inline `# glob-exempt: <rationale>` marker
says an empty match set is that site's normal state. A read under a `+`
or `:+` operator is not such a read: those emit only the alternate word
and never the value the variable holds, so no pattern it holds can
expand there. That last shape is decided at the read rather than at the
assignment, and only within one file: a name a sourced library assigns
is not seen, the value read is never traced back to the assignment that
produced it — a name given a pattern on one branch and a data list on
another is reported — and a pattern reaching a loop head or an array
element through a command substitution or an indirect expansion is not
read at all. A site both the literal and the laundered shape match
earns one record, one diagnostic and one exemption, as every other
position here does. A filter-driven scan narrows an
already-enumerated set through `filter_into` — a variable named `FILTER`
or ending `_FILTER` may be read at file scope to reach that call, but
not again inside a `for` or `while` loop over the narrowed selection,
nor in a function that loop calls — one hop out; a function called only
by that function still evades and stays outside what this pass decides
— and not at all in a file that never calls `filter_into`, unless an
inline `# filter-exempt: <rationale>` marker says the direct read is
deliberate. Copying a filter value into a target whose own name does not
match that same pattern is a violation at the assignment, wherever the
copy is later read, because every one of the checks above keys on the
name of the variable being read and a value under a fresh name would
otherwise satisfy the letter of all three while re-introducing the
defect. Those are the positions a single pass over the tree
decides; a pattern that reaches a scan by any other route is outside
what this lint sees, and the rule is stated no wider than that.

Every marker must open its comment: the comment's text is read from
the syntax tree, not the raw line, and the marker word has to be the
first thing in it — which is what makes the match immune to a `#`
inside a string or an expansion earlier on the line.

The property being protected is scan breadth, not producer status. A
producer that fails is the easy half; the hard half is a producer that
succeeds and enumerates nothing: `GIT_INDEX_FILE=/nonexistent git ls-files` exits 0 and prints not one path, which every status check in
the world reads as a clean tree. A lint that scans an empty set finds
no violations and exits 0 — off, and green. So breadth has to be
asserted rather than inferred, and `enumerate_into` is where that
assertion lives: routing every enumeration through it makes the
assertion structural instead of something each call site has to
remember.

A glob scan fails the same way from the other end. Under `nullglob` a
pattern matching nothing expands to nothing: a loop body never runs, an
array comes back empty, no violation is found and the run exits 0 — so
a scan root that exists and holds nothing scores as a clean tree.
`glob_into` is the same assertion for both shapes: it expands the
patterns, fills the array and refuses an empty match set, and whatever
reads that array afterwards walks an ordinary list.

A pattern held in a variable fails that same way, and the quoting at
the read is what decides whether it does: `pat='scripts/*.sh'` expands
nowhere until something reads it, so `for f in ${pat}` runs exactly the
unasserted scan a bare pattern runs, while `for f in "${pat}"` iterates
one literal string and `glob_into files 'shell sources' "${pat}"`
asserts the match set. The verdict therefore lands at the read, unlike
the two copying rules, which land at the assignment because the value
they follow is identified by name or by literal wherever it goes.

A filter-driven scan fails a third way, one layer past enumeration and
globbing: `filter_into` narrows a set the other two helpers already
proved non-empty, and it is the one place that narrowing's own
cardinality is asserted. A loop that reads the raw filter variable
again — directly in its own body, or one hop out in a function the loop
calls by name — instead of trusting the selection `filter_into` handed
back, re-applies the filter test outside the helper. Whether that second
application runs over the narrowed selection — where it is merely
redundant, since every path there already matched — or over a set the
helper never narrowed is not decidable at the read site, and the
second is the empty-root failure the helper exists to catch: a filter
matching nothing selects no path, the loop body never fires, and the
run exits 0. A file that reads a filter variable and never calls
`filter_into` at all is the same hole with no call site to point to:
nothing anywhere in that file asserts the selection the read implies
is non-empty.

A filter-driven scan fails a fourth way, sideways rather than past any
of the first three: copying the filter value into a variable whose own
name is not `FILTER` or `*_FILTER` moves every later read of that copy
outside all three checks above at once, because each one keys on the
name of the variable being read rather than tracing where its value
came from. The copy is flagged at the assignment regardless of where or
how many times the copied name is later read, which is what keeps the
rule decidable in one pass rather than requiring the kind of dataflow
tracing the other three checks were built to avoid.

That is what makes all three rules decidable in one pass. Associating a
scan with a cardinality test written an arbitrary distance later is not
something a textual rule can do; asking whether a producer is an
argument to the helper is local to one call expression, so is asking
whether a `for` loop or an array assignment expands a pattern in its
own words, and so is asking whether a filter-named read falls inside a
loop's own extent or outside every `filter_into` call in the file.
Whether a name read at one of those two glob positions is one this file
gives a pattern is a question about the same tree, answered by
collecting that file's assignments in the same walk, which is what
keeps the laundered read a file question rather than a dataflow one.
Patterns handed to `glob_into` are arguments of a `CallExpr` — never
`WordIter` items, never array elements — and reach it quoted, so a
compliant call site cannot false-hit the glob rule however many
metacharacters it carries; a pattern-bearing name reaches it quoted
too, and a quoted read is a part of the quoted string rather than of
the word, so it is not a read the rule counts either. A filter-named
read handed to `filter_into`
as its own argument is excluded from the filter rule the same way, and
the sanctioned `readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"` shape
stays legal under the alias check for the same reason: its own target is
itself a filter name, so a compliant call site cannot false-hit either
rule it satisfies.

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

The count of scan sites classified — producer calls plus a producer
name copied to a variable, plus `glob_into` call sites plus glob loops
plus glob array assignments plus an unquoted read of a pattern-bearing
name at either, plus `filter_into` call sites, plus filter reads inside
a loop and inside a function one hop out, plus the single read reported
in a file that calls the helper nowhere, plus a filter value copied to
an unwatched name — is itself asserted nonzero (unless
LINT_ALLOW_EMPTY_SCAN=1). A grammar that
silently recognized nothing would report "0 violations" and exit 0 —
the same clean line a genuinely scan-free tree prints — leaving this
gate off while green, which is the exact failure it exists to prevent
one level down.

Each rule owns its own marker word, and a marker excuses only the kind
of site it names: a rationale for running a producer outside the
enumeration helper says nothing about whether a glob's match set may
come back empty or a loop may read a filter variable directly, and the
reverse holds in every direction.

A site a marker was written for can still be rewritten into a
compliant shape, moved, or dropped from the file entirely while the
comment above it stays behind, so every marker word this lint owns is
censused independently of whichever rule's sites a file happens to
hold today: a `# glob-exempt:` comment sitting where the glob rule
finds nothing to excuse is unconsumed exactly like an
`# enumerate-exempt:` comment would be, because a marker protecting
nothing keeps asserting the decision it was written for regardless of
which of the three words it is spelled with. A marker classification
never consumed while walking a file is reported on its own line, and
the clean summary line carries the count as a fourth field alongside
files scanned, sites classified and exemptions applied.

Honors PATHS_OVERRIDE (newline-separated file list) for fixtures, and
LINT_ALLOW_EMPTY_SCAN=1 to accept a run whose scan-site tally (or whose
enumerated file count) comes back zero.
Exit 0 clean, 1 on a producer outside `enumerate_into`, a producer name
copied to a variable, a `for` loop expanding a glob at its own head, an
array assignment expanding one in its element list, a `for` loop or an
array assignment expanding a variable this file assigns a glob pattern,
a loop reading a filter variable directly, a filter read in a function
that loop calls, a script reading a filter variable without ever
calling `filter_into`,
an assignment copying a filter value to a name outside the filter
pattern, an exemption marker with no rationale, or an exemption marker
that excuses no site this pass classified, 2 when a required tool is
absent, the scan set could not be enumerated (or classified nothing),
a named path does not exist, or a file could not be parsed as shell.

### scripts/check-ephemeral-refs.sh

Lint: every Markdown file, shell script, Nix source and
YAML source in the repo must carry no ephemeral references — PR/issue
refs, prose dates, planning/review-pass labels, or literal `.claude/`
paths.
Markdown is read as prose; shell is read as comments only, lifted from
the `shfmt` syntax tree; Nix is read as the comments that start their
own line, both `#` line comments and `/* */` block comments; YAML is
read as the `#` comments that start their own line, block scalars
included.
Only the sources whose raw text carries a candidate token are
extracted; the rest are set aside and reported as such.
Default mode blocks (exit 1); --advisory mode
suppresses findings, not defects: it warns on fuzzy causal-history
phrases and exits 0 on those, but a could-not-run (unterminated
fence/generated block/Nix block comment, unparsable shell, a shell
scan, a Nix scan or a YAML scan that extracted no comments, a failed candidate
scan, a structural pass that read fewer sources than were set aside
for it, a class regex that fails its own canary, failed source
enumeration) still exits non-zero the same as the default pass.

**Options:**

- `--advisory` — suppress findings, not defects: warn on fuzzy causal-history phrases and exit 0 for those, but still exit 1 on an unterminated fence/generated block/Nix block comment and 2 on a failed source enumeration, a failed candidate scan, a class regex that fails its canary, a structural pass that read fewer sources than were set aside, an unparsable shell source, a shell scan that extracted no comments, a Nix scan that extracted no comments, or a YAML scan that extracted no comments

### scripts/check-exit-contract-documented.sh

Lint: every script directly under `scripts/` that can reach
exit 2 says so in its header. Exit 2 means the check could not run — a
required tool absent, an input missing or malformed — and exit 1 means
it ran and found a violation. A header promising only 0 and 1 tells a
reader, and anyone wiring the script into a new caller, that a
could-not-run cannot happen; a caller written against that promise
treats one as a finding and reports a violation nobody observed.

A script can reach exit 2 two ways, and both count:

- a literal `exit 2` / `return 2` on a line that is not a comment
- a call to a library helper that exits 2 in the caller's shell:
    require_tool, enumerate_into, glob_into, filter_into,
    require_json_payload, payload_source_into, read_json_payload_into,
    make_temp
    Detection is textual and direct-call-only: a helper reached through
    another helper is already covered by that helper's own call site, and
    chasing the source graph would report a script for code it never runs.

The header is every line above the first line that is neither blank nor
a comment. It is unwrapped before matching, because these contracts
routinely wrap mid-sentence and a line-oriented match cannot see a
clause split across two lines.

Four contract shapes count as documenting exit 2, which is every shape
the tree uses:
Exits 2 when … (a dedicated sentence)
Exits 0 on …, 1 on …, 2 on … (a comma-separated list)
Exit: 0 …, 3 …, 2 usage error. (the same list, any order)
Exit codes: … a `2` item line … (an enumerated block)
The list forms match only within one sentence, so a `2` in unrelated
prose later in the header does not excuse a missing contract. The item
form requires the 2 to stand alone as a token: `2FA` and `v2` are prose,
not exit codes, and one of them appears in a header this rule covers.

Scope is `scripts/*.sh` only. Libraries under `scripts/lib/` exit in
their caller's shell and have no standalone contract of their own —
documenting that exit is the obligation of the callers this rule reads.

No exemption marker. Every script can describe its own exit codes, so a
hit is always fixed by writing the sentence rather than by excusing the
script.

Honors SCRIPTS_DIR_OVERRIDE (default: scripts) and
LINT_ALLOW_EMPTY_SCAN=1 for fixtures.

Exits 0 when every script that can reach exit 2 documents it, 1 on any
script that cannot. Exits 2 when the check cannot run: the scan set
matches no script, which is a could-not-run rather than a clean tree.

### scripts/check-flake-lock-provenance.sh

Lint: a `flake.lock` bump that `flake.nix` does not
account for may only move `rev`/`narHash`/`lastModified`. Fails when a
top-level input is added, removed, or repointed, or when any node
present in both base and head has its source identity
(owner/repo/type/url/ref/flake/...) changed, unless `flake.nix` itself
declares a different `url` for that input between base and head.
Gates the auto-merged weekly flake.lock update so a source-level
repoint of an input cannot slip into the build/dev closure
undeclared.

### scripts/check-flake-lock-staleness.sh

Lint: every top-level `flake.lock` input was refreshed
recently enough that the mechanism responsible for refreshing it is
demonstrably still running. Fails when an input's `locked.lastModified`
is older than the threshold declared for it.

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

Lint: every `gh api` invocation and every `api.github.com`
request in scripts/\*.sh passes an explicit
`X-GitHub-Api-Version: <date>` header.

### scripts/check-gh-attestation-repo.sh

Lint: every `gh attestation verify` invocation across
workflows, composite actions, scripts, nix modules, the justfile, and
docs passes `--repo rvenutolo/linPEAS-flake` so verification is bound
to this repository.

### scripts/check-guard-exit-code.sh

Lint: no script anywhere under `scripts/` may exit 1 out
of a guard whose test is only an availability check, none may create
a temp file with a bare `mktemp`, and none may take a required value
through a `${var:?}` expansion. The exit codes separate what the
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

The second rule covers the same class one level down. An unwritable
`TMPDIR` makes `mktemp` exit 1, and an unguarded `x="$(mktemp)"` under
`set -e` kills the caller with that same 1 — so a machine that cannot
hand the script a scratch file reports as a repo carrying a violation.
Every creation therefore routes through `make_temp`
(`scripts/lib/temp.sh`), which reports the failure as exit 2; that
library holds the one sanctioned bare invocation and is the only file
this rule skips. Matching is by command position — line start, a
command substitution, a pipe, a separator, a negation, a group
opening, or a loop/branch keyword — so prose naming the command,
including a parenthetical, is not a hit.

Escape hatch: `# exit-code-exempt: <rationale>`, on the exit line of a
guard whose missing input genuinely IS the finding, or on the line of a
bare temp-file creation whose failure IS the finding. The marker has
to open the comment — matching drops everything up to and including
the line's first `#` and requires the remainder to begin with the
marker word, so prose naming it exempts nothing — and the rationale
has to be non-empty. Any earlier `#` on the same line, whatever
produced it — a `${x#y}` expansion, a `#` inside a string, or
anything else (`printf 'a#b\n'; exit 1 # exit-code-exempt: <why>`) —
is read as that first `#`, so a genuine trailing marker can be
missed; the miss reports the site as a hit rather than silently
excusing it, which is the direction this lint is safe to fail in. A
clean run prints the exemption count, so the exempt set is stated
rather than open-ended.

The same predicate that opens a marker's comment for classification
also opens it for a census that runs after every hit and bare-mktemp
check: a line whose comment opens with `exit-code-exempt:` is recorded
as the file is read, marked consumed only when a hit or a bare mktemp
is actually routed through it, and any recorded line left unconsumed
once the file is done is reported as its own finding and fails the
run — a marker still reads as a decision someone made about the guard
beneath it, and keeps asserting that decision after the guard was
rewritten into a compliant shape, moved, or left the file.
Classification and the census share this one predicate rather than
two, so a marker an earlier `#` hides from classification is hidden
from the census identically, and is never both missed as an exemption
and reported as unconsumed. The clean summary line reports this count
too, as a third field alongside scripts scanned and exemptions
applied.

The scan recurses. The shared libraries under `scripts/lib/` decide
which exit code their callers report — `enumerate_into` is where a
could-not-run enumeration becomes exit 2 for every lint that uses it —
so a scan stopping at the top level would vouch for the code that
settles the very convention this lint enforces.

Honors SCRIPTS_DIR_OVERRIDE (default: scripts) for fixtures.
Exit 0 clean, 1 on any hit or an exemption marker that excuses no
guard this pass classified, 2 on operational error.

### scripts/check-harden-runner-block.sh

Lint: every step-security/harden-runner step uses
egress-policy: block with a non-empty allowed-endpoints list,
preventing network-level egress to unlisted hosts.

### scripts/check-harden-runner-first.sh

Lint: every job in .github/workflows/\*.yml begins
with `step-security/harden-runner@<sha>` as its first step, so the
eBPF monitor installs before any I/O.

### scripts/check-harness-assert-wired.sh

Lint: every output-asserting test harness under
`tests/*.test.sh` is wired to the cross-scenario discrimination gate
in `scripts/lib/harness-assert.sh`, no harness registers a
discrimination exemption, and every parity exemption comes from an
allowlisted harness.

### scripts/check-harness-preamble.sh

Lint: every test harness matching `tests/*.test.sh`
opens with the canonical preamble — `#!/usr/bin/env bash` as the
exact first line, `set -Eeuo pipefail`, the tab/newline IFS line,
and a `readonly REPO_ROOT` derived from
`git rev-parse --show-toplevel`.

### scripts/check-job-timeout-minutes.sh

Lint: every job under .github/workflows/\*.yml
declares an explicit `timeout-minutes`, bounding blast radius
from hung jobs. Reusable-workflow jobs are exempt.

### scripts/check-jsonschema.sh

Validate repo config files (renovate.json, workflow
YAML, composite-action YAML, .markdownlint.json) against pinned
JSON Schemas using `check-jsonschema`.

### scripts/check-lib-source-tool-free.sh

Lint: a script under `scripts/` — sourced libraries
included — never resolves a `source`/`.` library path through a
command substitution, whether the substitution names `BASH_SOURCE` or
something else entirely, and `BASH_SOURCE` never appears inside a
command substitution anywhere else in the file either.

`BASH_SOURCE[0]` is how a script locates its own directory to source a
shared library. Feeding it through a command substitution needs
`readlink` and/or `dirname` on PATH, and runs above the guard whose
whole job is naming a missing tool — a script whose PATH lacks either
tool dies at exit 127 naming `readlink`, a could-not-run reported
under neither the exit code this repo reserves for it (2) nor a
diagnostic naming what was actually absent. That is true wherever the
substitution sits: directly on the `source` line (`source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/log.sh"`), or one
line earlier into a variable the `source` line then reads (`_lib_dir=" $(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"` followed by `source "${_lib_dir}/lib/log.sh"`), so this half of the rule scans every line
of every file rather than source lines alone.

A `source`/`.` line can also shell out to build its path without ever
naming `BASH_SOURCE` — `source "$(git rev-parse --show-toplevel)/scripts/lib/log.sh"` dies exactly the same way under
a stripped PATH, at whatever tool the substitution invokes. This half
of the rule is scoped to library source lines: a path under a `lib/`
directory, or any source line inside a file that is itself under a
`lib/` directory (a library resolving a sibling). Both are structural
tests on the line and the file rather than a list of library
basenames, so a library added later stays covered without the lint
itself needing an update.

`${BASH_SOURCE[0]%/*}` needs nothing on PATH: the shell performs the
trim itself, with a `.` fallback for a bare-filename invocation where
the expansion strips nothing. A bare `${BASH_SOURCE[0]%/*}` with no
bare-filename fallback stays legal: it is tool-free, and the case it
misses is an invocation no caller in this repo makes. A comment line
may still name either banned shape without tripping the check on its
own documentation.

Breadth is asserted on the same count the source-path half of the rule
scans: the run reports how many library `source .../lib/*.sh` lines it
read, and reading none is a broken scan reported as a could-not-run
rather than a clean tree, whether the scan root holds no shell script
at all or holds scripts that never source a library.
`LINT_ALLOW_EMPTY_SCAN=1` suppresses that guard for a scan root that
deliberately holds none.

Honors SCRIPTS_DIR_OVERRIDE for fixtures. Exits 0 clean, 1 on any
violation, 2 if the scan set is empty or unreadable.

### scripts/check-lint-shell-tools.sh

Assert every tool the batched `.#lint`-hosted invariant-lint
groups (lint-workflow-security, lint-script-hygiene) rely on is present on
PATH. These groups run inside devShells.lint in CI; this guard turns a
dropped tool into a named failure instead of a cryptic mid-check error.
Keep EXPECTED in sync with the lintTools list in nix/devshell-lint.nix.

### scripts/check-lock-derived-docs.sh

Lint: every workflow that writes a flake.lock runs a
generator for each freshness hook that declares `flake.lock` a
trigger, and may commit exactly the lock plus the outputs those
generators declare with `@generates` / `@generates-block`.

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
`nixpkgs` registry ref across workflows, composite actions, scripts,
and shell-fenced markdown. Allowed alternatives use the repo's own
flake or an explicit commit pin.

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

### scripts/check-payload-shape-scenario.sh

Lint: every script that reads an externally-supplied
payload carries a harness scenario feeding it a malformed payload and
asserting exit 2. A shape gate (`require_json_payload` or an
equivalent hand-rolled `die_op` guard) that regresses or was never
written is invisible to every other lint in this repo, because none of
them runs the scripts under test — only a scenario that actually drives
a malformed payload through the gate and checks the exit code proves
the gate still fires. This lint therefore gates the *scenario's
existence*, not the gate's source text: grepping a script for
`require_json_payload` would pass a script that calls it on a path a
scenario never exercises, and would fail a script whose gate is
hand-rolled (die_op) but genuinely covered.

### scripts/check-payload-source-helper.sh

Lint: no shell file names a payload's source by hand, and
no shell file under `<scripts>` (excluding `lib/`) reads a JSON payload
by hand either.
`payload_source_into` (scripts/lib/payload.sh) fills a caller variable
with the override variable's name when a fixture supplies the payload
and with the API route or config filename otherwise, so an assignment
that sets a variable to a bare `*_OVERRIDE` variable name is a copy of
a rule the library already owns. Ten such copies existed across nine
scripts, in two spellings that had already drifted apart from each
other, which is what a rule with no enforcer costs: the shape gate they
all feed reads the source name verbatim into every diagnostic, so a
copy that resolves the override differently from the reader beside it
names a source the run never used.

--- Why an AST, not a grep ----------------------------------------------

The banned shape is a text-shaped shortcut, and a gate whose purpose is
rejecting one must not accept one itself. A textual matcher keyed on
`=('|")?[A-Z_]*_OVERRIDE` reads the override name out of prose, out of
a heredoc, and out of this file's own diagnostics; it also misses the
same assignment written unquoted. `shfmt --to-json` answers the only
question that matters — is this a variable assignment whose entire
value is one literal word spelling an override variable's name — and
answers it identically for all three spellings the parser distinguishes:
a single-quoted word, a bare literal word, and a double-quoted word
wrapping one literal part.

Both `CallExpr` assignments (`src='X_OVERRIDE'`) and `DeclClause`
arguments (`local src='X_OVERRIDE'`, `readonly`, `declare`, `export`)
are read. The parser files those under different node types, and the
two scripts that named a source inside a function body would have had
the declared form available to them, so a scan of bare assignments
alone leaves the shape most likely to be written next unreachable.

--- Exemption -----------------------------------------------------------

An assignment that spells an override variable's name for some reason
other than naming a payload source — an operator message telling a
reader which variable to set, say — is excused by an inline
`# payload-source-exempt: <rationale>` marker anywhere in the file,
matching this repo's existing `payload-subject-exempt` /
`enumerate-exempt` / `glob-exempt` convention: the rationale lives
beside the code it excuses rather than in a hand-maintained doc table
that drifts silently. A marker with an empty rationale excuses nothing
— an exemption nobody has to justify is a way to switch the rule off in
place. A marker on a file holding no assignment the rule matches is
itself reported, and that report is produced before any violation is,
so a stale marker surfaces on a tree where the rule is otherwise
obeyed everywhere.

--- The read rule ---------------------------------------------------------

`read_json_payload_into` (scripts/lib/payload.sh) turns a file path
into a shape-checked payload while reporting an absent, unreadable, or
non-regular-file path as a could-not-run. A `cat -- <path>` command
skips every one of those guards, so a hand-rolled read that later
feeds `require_json_payload` reproduces the helper's job with none of
its could-not-run handling — the same cost the source-naming rule
above exists to stop, one level earlier in the same read.

The rule is broader than "feeds require_json_payload": every
`cat -- <path>` command under `<scripts>` outside `<scripts>/lib` is a
violation, whether or not this run can prove its output later reaches
the shape gate. A predicate that only fires when it can trace the read
into `require_json_payload` by variable name misses a read wrapped in
its own fetch function — the read and the gate then share no variable
name for a dataflow check to follow — so the rule does not attempt
that trace at all.

Capturing the output is likewise not part of the predicate. A read
whose bytes go straight to stdout skips the same three guards a
captured one does, and it is the shape a fetch helper writes when its
caller does the capturing, so scoping the rule to `x="$(cat -- ...)"`
would exempt the reads most likely to be written next.

Two shapes read a temp file without hand-rolling anything: a read
whose path traces back to a `make_temp` (or `mktemp`) result in the
same file is exempted automatically, and a `# payload-read-exempt: <rationale>` marker excuses the rest, matching this file's
`payload-source-exempt` marker in every other respect — a marker with
no rationale excuses nothing, and a marker on a file holding no
`cat --` command the rule matches is itself reported, before any
violation is.

What the rule keys on also bounds what it reaches: a payload read
written as `$(<file)`, `mapfile`, a `while read` redirection, or a
file operand handed to `jq`/`yq` is not a `cat --` command and no part
of this scan sees it.

--- Breadth -------------------------------------------------------------

The scan set is `<scripts>/*.sh`, `<scripts>/lib/*.sh` and
`<tests>/*.sh`. The library arm is not optional: the helper itself
lives there, its neighbors are the files most likely to copy it, and
the older shell-hygiene lints in this repo stop at the top level. The
read rule narrows to `<scripts>/*.sh` alone — a hand-rolled read in a
library or a harness is not the shape this rule polices, since neither
one is a caller deciding how to read its own payload. The clean
verdict reports files scanned, assignments examined, and reads
examined rather than a bare "ok", because a detector that stopped
reaching either one and a tree with nothing to report emit the same
exit code otherwise.

Measured, not assumed: this file's own prose does not self-match. The
finished lint run against a scan root holding only this script reports
zero violations across every assignment it examines there — each
mention of the banned shape here is a comment or a format string,
neither of which the parser files as an assignment — so this file needs
no exemption marker of its own. The count itself is deliberately not
quoted: it moves with every edit to this file, and a quoted tally that
has drifted reads as a measurement nobody re-took.

Honors SCRIPTS_DIR_OVERRIDE (default: scripts), TESTS_DIR_OVERRIDE
(default: tests), and LINT_ALLOW_EMPTY_SCAN for a scan root that
deliberately holds no assignment and no read at all.
Exit 0 clean, 1 on a hand-named source, a hand-rolled read, or a stale
exemption marker, 2 when the scan set cannot be enumerated, holds no
assignment or no read, a required tool is missing, or a file cannot be
parsed as shell.

### scripts/check-permission-scopes.sh

Per-job GITHUB_TOKEN write-scope allowlist lint for
GitHub Actions. Fails when a job grants a write scope absent from
.github/permission-scopes.yml, when an allowlist entry is stale, or
when an allowlist scope list is not sorted.

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

Both sides of a moved SHA are first dereferenced through the
annotated-tag-object API, so a pin naming a tag object and a pin
naming that tag's commit compare equal instead of reading as a
repoint. This does not soften the gate: a tag object's hash covers
the commit it tags, so retagging a released version moves the tag
object too and the resolved commits still differ. Container digests
name no git object and resolve to themselves.

### scripts/check-pr-workflows-no-secrets.sh

Lint: no workflow triggered by `pull_request` /
`pull_request_target` references any `secrets.*` other than
`secrets.GITHUB_TOKEN`.

### scripts/check-pre-commit-hooks-sha-parity.sh

Lint: the SHA embedded in `flake.nix`'s
`pre-commit-hooks` input URL matches `flake.lock`'s pinned
`pre-commit-hooks.locked.rev`.

### scripts/check-protect-main.sh

Lint: the live `protect-main` branch ruleset matches
the desired posture, the in-tree mirror at
`.github/rulesets/protect-main.json`, and the `## Required contexts`
table in `docs/security/required-checks.md`.

### scripts/check-pull-request-target-absent.sh

Lint: hard-fail if any workflow under
.github/workflows/\*.yml uses the `pull_request_target` trigger,
foreclosing the canonical Actions privilege-escalation footgun.

### scripts/check-ratchet-pin-audit.sh

Lint: the ratchet-pin-audit workflow keeps its
hardened shape — empty top-level permissions, harden-runner first,
typed reason tokens in the notify body, ratchet in the
nix/devshell.nix devShell, and a documented ratchet version matching
the one the devShell ships — so future edits cannot silently weaken it.

### scripts/check-renovate-config-validator.sh

Validate renovate.json against the upstream Renovate
config schema using `renovate-config-validator --strict --no-global`.
Catches typoed keys, wrong-type values, and unknown options that
per-tool linters miss. Complements scripts/check-renovate-invariants.sh,
which asserts repo-policy invariants on top of a valid schema.

Honors RENOVATE_JSON_OVERRIDE for fixture testing.
Exits 0 on a valid config, 1 on any validation error, 2 when the check
cannot run — the config is absent, unreadable, not a regular file, or
the validator itself is not on PATH. None of those says anything about
the config's validity, so none may borrow the rejection code.

payload-subject-exempt: a malformed config is this script's verdict, not an obstacle to it — the validator rejects one at exit 1, so there is no could-not-run outcome for a scenario to prove

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
error — the config cannot be read at all (absent, unreadable, or not a
regular file), its shape fails validation, the file enumeration failed
or came back empty, or jq cannot read a customManager's declarations —
so no verdict about the markers is available and reporting one would
blame a marker for a config-shape problem.

### scripts/check-required-checks-no-paths.sh

Lint: no workflow listed in
docs/security/required-checks.md declares `paths:` or
`paths-ignore:` under `on.pull_request:` — avoiding the auto-merge
path-filter skip trap.

### scripts/check-run-block-strict.sh

Lint: every block-scalar or newline-carrying `run:`
block under `.github/workflows/*.yml` (or `.yaml`) and
`.github/actions/**/action.yml` (or `.yaml`) starts with
`set -Eeuo pipefail` as its first non-blank, non-comment line.

### scripts/check-scorecard-threshold.sh

Reads OSSF Scorecard JSON on stdin; exits 1 if any
check scored below 10, exits 2 if stdin cannot be read as scorecard
JSON at all. Prints offender names + scores, or the could-not-run
diagnostic, to stderr.

### scripts/check-script-has-test.sh

Lint: every `scripts/check-*.sh` has a matching
`tests/check-*.test.sh` and vice versa, modulo an explicit EXEMPT
list.

### scripts/check-script-shebang-pipefail.sh

Lint: every executable script under `scripts/` starts
with `#!/usr/bin/env bash` (exact first line) and carries
`set -Eeuo pipefail` as its own line (line-anchored; a trailing
addition such as `-x` is accepted); every sourced library
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

### scripts/check-size-label-ignores.sh

Lint: the size-label action's `IGNORED` list holds exactly
the files this repo's generators declare they own — every `@generates`
path is on the list, no `@generates-block` path is, and every other
entry is one of this lint's declared exemptions.

### scripts/check-tag-protection.sh

Lint: the live `release-tag-protection` ruleset
matches the desired posture (tag target, active enforcement, ref
include pattern, required rules).

### scripts/check-test-reachable.sh

Lint: every test harness is executed by some runner. Two scan
sets: `tests/*.test.sh`, and the tracked harnesses under `.claude/`. The
second comes from `git ls-files` rather than a glob because `.claude/` is not
gitignored and is overwhelmingly untracked — a glob would report dozens of
local-only harnesses as violations, and only the committed set is a CI
concern. check-script-has-test guarantees a test FILE exists for each script;
it does not guarantee the test ever RUNS. A harness reachable by no runner is
a coverage no-op — the regressions it would catch pass green while the
pairing guard stays satisfied. Reachability is via one of four runners:

1. the HARNESSES array in scripts/run-harness-group.sh (harness-group job),
1. the tests/refresh-\*.test.sh glob in scripts/run-doc-freshness.sh,
1. a .github/lint-groups.yml member -> tests/check-<name>.test.sh
    (executed by scripts/run-lint-group.sh), or
1. a direct `tests/<x>.test.sh` invocation in a .github/workflows/\*.yml.
    A tests/ harness is keyed by basename and a tracked `.claude/` one by its
    repo-root-relative path, which is exactly how each is spelled in the
    HARNESSES array, so the two key spaces cannot collide.

Overridable dirs/paths let the paired test harness point at fixtures.
Exits 0 if every harness is reachable, 1 otherwise. Exits 2 when the
check cannot run: a runner manifest, the lint-group manifest, or a
workflow file cannot be scanned for the harnesses it wires; the
tracked harnesses outside `tests/` cannot be enumerated; a temp file
cannot be created; or a scan set comes back empty, which is a
could-not-run rather than a tree with nothing to check.

### scripts/check-tool-guarded.sh

Lint: every third-party tool a script under `scripts/`
invokes must be guarded somewhere in that same script. A guard is
`require_tool <tool>`, a `command -v <tool>` availability test, or a
library helper that guards the tool on its caller's behalf.

An unguarded tool does not fail loudly. It fails as whatever the
surrounding code does with a non-zero status, and every one of those
readings is wrong:

- A shape probe written as `<tool> ... || die` reports the payload as
    malformed. The operator opens a file that is intact and looks for a
    field that is present.
- A guard that treats success as the violation — `if <tool> ...; then report` — scores every input clean, because an absent tool cannot
    succeed. The check exits 0 having read nothing, which is the only
    failure mode here that no caller can see.
- An enumeration ending in `|| true` comes back empty, and a lint that
    asserts over an empty set asserts nothing.
- An unchecked command substitution ends the run under the tool's own
    status — 127 for an absent one — which the exit-code convention
    does not catalogue.

The convention this protects: 2 means the check could not run, 1 means
it ran and found a violation, 0 means it ran and found none. A missing
binary is a could-not-run in every case, and `require_tool` is what
says so.

Scope is tools a shell can genuinely lack. POSIX utilities and
coreutils staples are assumed present: guarding `grep` in every script
that greps would cost a hundred lines to describe an environment that
does not occur, and a rule nobody believes is a rule that gets
exempted.

The rule is presence, not position. A parse tree reports where a word
was written, and in shell that is not when it runs: nearly every script
here defines its functions above the `main` that calls them, so a tool
invoked at line 100 inside a function routinely executes after a guard
written at line 700. Ordering those two correctly needs a call graph,
and comparing the line numbers instead reports the tree's ordinary
layout as a defect. What is checkable without one — and what the nine
faults this rule was written for all violate — is whether the script
guards the tool at all.

Detection reads command words from `shfmt --tojson` rather than
matching text. A tool name occurs in comments, in message strings, and
in `@description` prose, and none of those is an invocation; a `||`
inside a `sed` or `awk` program text reads as shell control flow to a
line-oriented scan. The parser knows which words are commands and a
regex does not.

Honors SCRIPTS_DIR_OVERRIDE (default: scripts) and
LINT_ALLOW_EMPTY_SCAN=1 for fixtures.

Exits 0 when every invocation is guarded, 1 when one is not. Exits 2
when the check cannot run: `shfmt` or `jq` absent from PATH, a script
`shfmt` cannot parse, or a scan set matching no script.

### scripts/check-upload-artifact-strict.sh

Lint: every `actions/upload-artifact` step in every
workflow under `.github/workflows/*.yml` sets
`with.if-no-files-found: error` so empty-glob bugs hard-fail.

### scripts/check-uses-sha-pinned.sh

Lint: every `uses:` in `.github/workflows/*.yml` (or
`.yaml`) and `.github/actions/**/*.yml` (or `.yaml`) ends with a
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

### scripts/refresh-ephemeral-refs-gap.sh

Regenerate the ephemeral-refs-gap managed block in
docs/development/linting.md: the file types no ephemeral-refs extractor
claims and that nonetheless carry `#` comments. The corpus inverts the
lint's own type filter — same producer, same allowlist, all read from
scripts/lib/ephemeral-refs-scope.sh — so the page cannot describe a
narrower set of types than the ban leaves unread. Files the allowlist
skips sit outside both sets and are accounted for by the page's
allowlist bullet. A blocking-class shape found inside the corpus is
refused
rather than rendered: the prose around the block states the gap is
empty, and rendering a non-zero count would publish a page that
contradicts itself.

**Options:**

- `--check` — exit 1 if the block would change; exit 2 if the check

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

### scripts/refresh-pin-parity.sh

Regenerate the pin-parity managed block in
docs/architecture/auto-update.md: every tracked file carrying the
canonical pin-shape literal, grouped by path into enforcement and
documentation. The set is read from the tree on every run, so no
hand-written list can name a file that has stopped carrying the shape
or omit one that gained it. A file under tests/ is excluded; the block
says so in prose, because a versioning-scheme migration touches the
fixtures too and a silent omission would read as coverage.

**Options:**

- `--check` — exit 1 if the block would change; exit 2 if the check

### scripts/refresh-precommit-table.sh

Regenerate the precommit-table managed block in
docs/development/git.md from the current pre-commit hook manifest
in the flake.

**Options:**

- `--check` — exit 1 if the doc would change; exit 2 if the doc is

### scripts/refresh-scripts-reference.sh

Regenerate the scripts-reference managed block in
docs/reference/scripts.md from in-script shdoc-style annotations
parsed by scripts/\_script_docs.awk. Groups entry-point entries by
basename prefix into Check / Refresh / Other sections, then renders
each library under scripts/lib/ with one entry per annotated function
in a Libraries section.

**Options:**

- `--check` — exit 1 if drift; exit 2 if the doc or the awk parser is

### scripts/refresh-test-harnesses.sh

Regenerate docs/reference/test-harnesses.md, the census of
every tests/\*.test.sh harness: the file or file set it exercises and the
directories under tests/fixtures/ it reads. A harness names its subject
either by a SCRIPT= assignment pointing into scripts/ or by a
`# @subject` header annotation, and never by both, so the census can
neither render an unknown subject nor silently follow the stale one of
two disagreeing declarations. A fixture directory no harness names is
refused as well: a census that omitted it would describe a smaller tree
than the one on disk.

**Options:**

- `--check` — exit 1 if drift; exit 2 if the doc is missing, a harness

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
(`present`/`absent`) of six registry objects in the order
amd64@ghcr amd64@hub arm64@ghcr arm64@hub index@ghcr index@hub,
print `full` when all six exist, `none` when all six are absent, and
fail on any partial mix. Pure and side-effect free so the decision is
unit-testable without contacting a registry.

### scripts/classify-pin-ref.sh

Classify one SHA-pinned action ref for
ratchet-pin-audit: given the pinned SHA and the tag's resolved git
objects, print `current`, `drift`, or `skip-floating-major`. Pure
and side-effect free so the drift decision — including the
attack-detection branch — is unit-testable without contacting the
GitHub API.

### scripts/classify-refresh-notify-result.sh

Classify what `renovate-flake-lock-refresh.yml`'s
`notify` job should report. Given the `identify`, `compute-refresh`
and `push-refresh` job results followed by `identify`'s
`should_refresh` and `unmapped` outputs, print `failure` when a
refresh was attempted and did not land (or could not be attempted),
`success` when one landed or was already in place, and `skipped` for
the steady state where the `ci` completion was not a Renovate flake
bump. Pure and side-effect free so the decision is unit-testable
without a workflow run.

### scripts/classify-renovate-flake-input.sh

Classify one Renovate PR title into the flake input that
PR bumps: prints `pre-commit-hooks`, `nixpkgs-unstable`, or
`nixpkgs`. Drives the identify job of
.github/workflows/renovate-flake-lock-refresh.yml, which runs
`nix flake update <input>` on the PR branch. Pure and side-effect
free so the mapping is testable without a live Renovate PR.

### scripts/classify-renovate-pr-author.sh

Classify one PR author login as Renovate or not, printing
the canonical `renovate` spelling when it is. Drives the identify job
of .github/workflows/renovate-flake-lock-refresh.yml, which refreshes
`flake.lock` only on a PR that Renovate opened. Pure and side-effect
free so the mapping is testable without a live Renovate PR.

### scripts/compare-repro.sh

Compare two reproducibility-build hash JSON files.
Emits a markdown table to GITHUB_STEP_SUMMARY (or stdout if unset)
and exits 0 on full match, 1 on any divergence, 2 on bad input. Bad
input includes an absent, null, or malformed hash field: two builds
that both measured nothing are not a match.

### scripts/docs-audit-pressure.sh

Report docs-audit drift pressure since the last audit:
how many commits touched CI structure (.github/workflows, scripts,
.github/lint-groups.yml), and which job ids / lint-group members were
added or removed. Emits a Markdown body for the monthly docs-audit
reminder issue, terminated by a machine-readable PRESSURE=<n> line.

Freshness gates validate only generated blocks; hand-written prose about
CI drifts silently. CI churn is the best cheap proxy for that drift, so it
decides whether a semantic audit is worth running this month.

The diff base is the commit recorded in `.github/docs-audit-state`, which
`scripts/mark-docs-audit.sh` writes once an audit's fixes have landed. A
fixed-length window would measure churn the maintainer has already read
and audited, so its count could never fall to zero on a repo with a
steady commit rate — and the reminder issue's close condition reads that
count. Measuring from the audit point makes the number mean "CI-structure
commits nobody has audited yet", which is zero right after an audit and
grows only with unreviewed churn.

Body contents are restricted to integers and shape-validated identifiers
parsed from YAML — never commit subjects or other free text, which would
render as arbitrary markdown in the resulting issue.

Honors LINT_ALLOW_EMPTY_SCAN=1 to accept a ref whose workflows dir holds
no YAML.

Exit codes:
0 success (body on stdout, PRESSURE=<n> as the final line)
2 missing inputs / parse error / nothing enumerated to measure,
including an audit-state file that is absent, carries no
LAST_AUDIT_SHA=\<40-hex> line, or names a commit this history does
not contain

### scripts/gen-dashboard-data.sh

Generate docs/\_data/dashboard.yml for the MkDocs site
by aggregating pin metadata and live GitHub REST API data.

### scripts/inventory-action-pin-tags.sh

Enumerate every SHA-pinned `uses:` in
.github/workflows/*.yml|*.yaml and .github/actions/\*\*/action.yml
(or action.yaml), resolve each pinned SHA to its exact patch tag via
`gh api .../tags`, and emit a TSV mapping pin -> patch tag for
downstream rewrite tooling.

### scripts/mark-docs-audit.sh

Record the current commit as the point the semantic docs
audit was last run against. Writes `.github/docs-audit-state`, which
`scripts/docs-audit-pressure.sh` uses as its diff base and the monthly
`docs-audit-reminder` workflow reads through it.

Run this in the final fix PR of an audit cycle — once the audit's
findings are fixed, not when the audit is dispatched. The marker means
"everything up to here has been read and its drift resolved", and the
reminder issue closes on the count it produces; marking at dispatch
time would close the issue over findings still outstanding.

Writes the file only. Staging and committing stay with the caller, so
the marker lands in the same reviewed PR as the fixes it vouches for
rather than as a side effect of running a script.

Honors DOCS_AUDIT_STATE_OVERRIDE (default `.github/docs-audit-state`)
and REF_OVERRIDE (default `HEAD`) for fixtures.

Exits 0 once the marker is written. Exits 2 when it cannot be written:
the ref does not resolve to a commit in this history, or the target
path is not writable. There is no exit 1 — this script records a fact
rather than judging one, so it has no finding to report.

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
1 — findings present, the scanner ran and errored (image pull
failure, scanner internal error), or the command line is
unusable. A finding is told from a scanner error by the
`has-finding` line printed to stdout (`has-finding=true|false`)
— the same contract the CI workflow exposes via
`$GITHUB_OUTPUT` — and by the `classification=` field beside it.
2 — the scan could not proceed: `docker` is absent, `--sarif` was
given while `jq` is absent, or a per-file SARIF temp file could
not be created. The two tool guards report before any workflow
file is read and print the `infra-failure` classification
themselves; the temp-file failure reports itself, and can land
after part of the directory has already been scanned. Either
way the hook and the job still fail; only the diagnosis
differs.

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

## Libraries

### scripts/lib/awk-path.sh

Make a path unambiguous as an `awk` file operand.
`awk` reads an operand whose text is `name=value` as a variable
assignment rather than a filename, then finds no file operand, reads
stdin, and exits 0 having scanned nothing — so a relative path whose
first component contains `=` scores as an empty file. `--` is no help:
POSIX makes operand assignment parsing independent of it, and gawk
treats a `--` placed after the program as a filename.
Source after `set -Eeuo pipefail`.

#### awk_path()

Print a path in a form `awk` cannot read as an assignment.
The prefix is conditional because `./` ahead of an absolute path
resolves as a relative one.

**Args:**

- `$1` — path

**Stdout:**

- the path, `./`-prefixed when relative

### scripts/lib/enumerate.sh

NUL-safe filesystem enumeration with producer-status and
breadth assertions. A path is the one shell datum whose byte space
includes the newline delimiter, so a line-oriented handoff can drop a
file that exists: `git ls-files` C-quotes such a name onto one line,
`find` splits it across two, and either way the consumer's `[[ -f ]]`
gate skips it while the scan still reports a plausible file count.
Source after `set -Eeuo pipefail`.

#### enumerate_into()

Run a NUL-emitting enumeration into an array, asserting
both that the producer succeeded and that it found something. Breadth
is asserted rather than inferred, because a producer that exits 0 with
empty output is exactly the failure a status check cannot see:
`GIT_INDEX_FILE=/nonexistent git ls-files` exits 0 and emits nothing,
which reads as a clean tree. The producer writes to a temp file rather
than a process substitution: a procsub discards the status this
function exists to check, and is banned repo-wide for that reason. The
temp file is removed on every return path instead of under a trap,
because traps are global in bash and callers install their own.
The temp file comes from `make_temp`, not from a bare `mktemp`:
an unwritable `TMPDIR` makes `mktemp` exit non-zero, and an unguarded
failed assignment kills the calling script with mktemp's own exit
status (1) — a could-not-run reported as "ran and found a violation"
inside the one function whose job is making sure that never happens.
The read loop's `|| [[ -n ${__enum_item} ]]` clause keeps a final
record that has no trailing NUL: `read -r -d ''` reports that record as
a failure even though it populated the variable, so a loop keyed only
on read's exit status silently drops the last path of a truncated or
malformed producer — the exact silent-drop failure this library exists
to end. `git ls-files -z` and `find -print0` both terminate every
record including the last, so this only fires on a broken producer.

**Args:**

- `$1` — name of the array to fill
- `$2` — human-readable label naming the producer, used verbatim in both
- `$@` — the producer command and its arguments

**Exit codes:**

- `2` — the producer failed, or the scan set was empty while

#### glob_into()

Fill an array from one or more globs, asserting the match
set is non-empty. The glob analogue of `enumerate_into`: under
`nullglob` a pattern that matches nothing expands to nothing, the loop
body never runs, no violation is found and the lint exits 0 — a scan
root that exists and holds nothing is scored a clean tree. Patterns
arrive as strings and are expanded here rather than at the call site,
because a caller that has not set `nullglob` would otherwise hand this
function the literal unexpanded pattern and it would count as one
match — the helper vouching for exactly the tree it exists to catch.
`globstar` is left as the caller set it, so a `**` pattern keeps the
reach it already had.

**Args:**

- `$1` — name of the array to fill
- `$2` — human-readable label naming the scan set, used in the diagnostic
- `$@` — the glob patterns, quoted so they reach this function unexpanded

**Exit codes:**

- `2` — the match set was empty while LINT_ALLOW_EMPTY_SCAN was unset

#### filter_into()

Narrow an enumerated path list to what a filter selects,
asserting the selection is not empty. `enumerate_into` and `glob_into`
assert the breadth of a scan set as it is produced; a filter applied
afterwards can throw all of it away again, and neither helper can see
that happen. A filter naming a file the tree does not hold leaves no
path to walk: the loop body never runs, no violation is found, and the
run exits 0 — the same clean line a genuinely clean tree prints. So the
selection is asserted where it is made. An empty filter value selects
everything, which keeps a caller that may or may not be filtering on
one code path rather than branching around this call.

**Args:**

- `$1` — name of the array to fill
- `$2` — human-readable label naming the scan set, used in the diagnostic
- `$3` — the filter value: a basename to select, or empty to select all
- `$@` — the paths to select from

**Exit codes:**

- `2` — the selection was empty while LINT_ALLOW_EMPTY_SCAN was unset

### scripts/lib/ephemeral-refs-scope.sh

The ephemeral-reference ban's scan scope: which file types
an extractor claims, which paths are skipped outright, and the class
regexes a scan matches against. Shared by the lint that enforces the
ban and by the generator that reports which types the ban leaves
unread, so a class that widens widens for both and the two stay
derived from one record set rather than two lists that drift. Source
after
`set -Eeuo pipefail`.

#### ephemeral_refs_pathspec_into()

Fill an array with the `git ls-files` pathspec selecting
every claimed file type. Filled through a nameref rather than printed,
because a pathspec is passed to git as separate arguments and a
command substitution would split `*.md` on the caller's IFS and glob it
against the working directory before git ever saw it.

**Args:**

- `$1` — name of the array to fill

#### language_of()

Language of one source, by extension. Extension is the
whole classifier: a shell library without a `.sh` suffix, and shell
embedded in a workflow `run:` block, are out of scope by construction
rather than by a content sniff that would have to guess.

**Args:**

- `$1` — src_rel source path relative to REPO_ROOT

**Stdout:**

- one of `md`, `sh`, `nix`, `yaml`, `other`

#### is_allowlisted()

True when the given source path is on the skip-entirely
file allowlist (`CHANGELOG.md`, `docs/releases.md`,
`tests/fixtures/**`, `.claude/**`).

**Args:**

- `$1` — src_rel source path relative to REPO_ROOT

### scripts/lib/generates.sh

`@generates` / `@generates-block` annotation parsing.
Source after `set -Eeuo pipefail`.

#### generator_declarations()

Read the comment header of each named script and emit one
record per output declaration, in file order. Parsing only: the caller
chooses which scripts to hand over, and the caller tallies what it
needs — duplicates are emitted as separate records because one caller
counts declarations while deduplicating paths into a map.

The header ends at the first line that is neither a comment nor blank,
so an annotation sitting in the body beside the code is not a
declaration; blank lines separate paragraphs of a header rather than
ending it. The plain name is a proper prefix of the block name, so the
two are kept apart by two independent means at once: each pattern
demands whitespace between the annotation name and its path, which is
what stops the plain pattern from matching a block line, and the
if/elif chain settles the longer name first so the kinds stay right
even if that whitespace requirement is ever loosened.

A read fault is reported by the return status rather than left to
errexit, because every call site captures this in a command
substitution inside an `if` — a context where errexit is suppressed —
so a fault that only set `$?` would reach the caller as a short record
stream, indistinguishable from scripts that declared nothing, and be
scored as agreement.

**Args:**

- `$@` — script paths to parse

**Exit codes:**

- `0` — every named path was read, including when none declared anything
- `1` — at least one named path could not be read

**Stdout:**

- one record per declaration, `<kind>\037<path>\037<script-path>`,

### scripts/lib/harness-assert.sh

Cross-scenario discrimination gate for test harnesses.
A harness asserts behavior by grepping a scenario's captured output for
a substring. If that substring also appears in a sibling scenario's
output, the assertion passes whether or not the asserted behavior
exists — green while verifying nothing. Record each scenario here and
call `harness_assert_verify` at the end of the run to fail on any such
substring, and on any two scenarios whose whole observable outcome is
the same — a pair that verifies one thing between them however each is
named. Source after `set -Eeuo pipefail`.

#### harness_assert_exempt()

Register a substring as legitimately shared with one named
scenario, or with every scenario when the second argument is `*`. Use the
wildcard for a global banner a script prints on every run of a whole
outcome class: such a substring still separates that class from its
opposite, which is the axis the assertion is about. Use the named form
when one failure path emits no token another lacks. The rationale is
mandatory so the weakening is reviewable.

**Args:**

- `$1` — substring
- `$2` — other scenario name or `*`
- `$3` — rationale

#### harness_assert_parity_exempt()

Register two scenarios as legitimately producing one
observable outcome. Two scenarios the gate cannot tell apart verify one
thing between them, so the pair needs a reason that a reviewer can
check: the scenarios must differ in what they exercise even though
nothing they emit says so, and no honest output could separate them.
The rationale is mandatory, and the pair matches in either order.

**Args:**

- `$1` — scenario name
- `$2` — other scenario name
- `$3` — rationale

#### harness_assert_record()

Record one scenario's asserted substring and the output
stream(s) the harness asserts against. Pass '' as the substring for a
scenario that asserts only an exit code — its output still belongs in
the comparison pool, because that is usually the output a failure-path
substring wrongly matches.

**Args:**

- `$1` — scenario name
- `$2` — asserted substring ('' if none)
- `$@` — one or more captured output files

#### harness_assert_also()

Attach another asserted substring to the most recent
record. Use when one invocation asserts several properties of its
output: recording that invocation once per property makes those records
byte-identical siblings, which the pairwise rule cannot separate and
the census scores as collapsed coverage. Each attached substring is
held to the same rule as the record's own.

**Args:**

- `$1` — substring

#### harness_assert_declares()

Return 0 if the record at the given index asserts the
given substring. Membership is a whole-line match against the record's
substring list, so one substring being another's prefix does not count
as the same assertion.

**Args:**

- `$1` — substring
- `$2` — record index

#### harness_assert_is_exempt()

Return 0 if the substring/other-scenario pair is exempt,
either by an exact pair or by a `*` wildcard registered for the substring.

**Args:**

- `$1` — substring
- `$2` — other scenario name

#### harness_assert_parity_is_exempt()

Return 0 if the two named scenarios are registered as a
parity exemption, in either order.

**Args:**

- `$1` — scenario name
- `$2` — other scenario name

#### harness_assert_verify()

Apply the pairwise rule, the identical-output rule and the
parity rule to everything recorded, print the census, and drop the pool.
Exit 1 if any asserted substring also occurs in a sibling scenario's
output, if two records share one output while asserting different
substrings, if two records share one output without a parity exemption,
or if nothing was recorded at all. The census names every group of
scenarios sharing one output before reporting the counts.

### scripts/lib/log.sh

Shared logging + ERR-trap helpers for repo bash scripts.
Source after `set -Eeuo pipefail`. The ERR trap captures the failing
exit code as its first action: it is read into the format string before
any other expansion, so nothing between the failure and the report can
reset `$?`. Timestamps come from bash's `printf` time format, so no
helper here needs a tool on PATH.

#### log()

Emit a timestamped level-tagged line to stderr.
The timestamp comes from bash's own `printf` time format rather than
`date`, so a diagnostic about a missing tool is not itself preceded by
a `date: command not found` line and an empty timestamp. The format
string is identical to the one `date` was given.

**Args:**

- `$1` — level
- `$2` — message

#### log_info()

Emit an INFO line via `log`.

**Args:**

- `$@` — message words, joined by spaces

#### log_err()

Emit an ERROR line via `log`.

**Args:**

- `$@` — message words, joined by spaces

#### require_tool()

Verify a required CLI tool is on PATH; exit 2 if missing.
Exit 2 means "could not run", which is what an absent tool is; exit 1
stays reserved for a violation the caller found. A freshness hook's
caller reads exit 1 as "the doc is stale, run the generator and commit",
so a missing jq reported as 1 sends the operator to regenerate a doc
instead of to install jq.

**Args:**

- `$1` — tool name

#### install_err_trap()

Install the shared ERR trap in the calling shell. Captures
the real failing exit code before any command substitution clobbers $?.

### scripts/lib/payload.sh

Shape gate for an externally-supplied JSON payload.
Source after `set -Eeuo pipefail` and after `lib/log.sh`.

#### require_json_payload()

Reject a payload whose shape the reads below cannot rely
on, as a could-not-run rather than as a finding.

A payload arriving from an API response, a tool's JSON output, or a
file written by automation carries no shape guarantee. Reading one
unguarded surfaces a malformed payload two ways, both wrong: `jq` dies
with a raw diagnostic under an exit code the convention does not
catalogue, or — worse — an absent field reads as an empty string and
the caller reports substantive drift. Exit 1 sends a maintainer after
posture nobody changed, and the exit code alone does not tell the two
apart.

One gate in front of every read, rather than a guard per read: a read
added later is then total by construction instead of depending on its
author remembering the convention.

The source is named by kind — an override variable name or an API path
— never by fixture path. A fixture path in output lets two harness
scenarios be told apart by their fixture rather than by their
behavior.

An empty or whitespace-only payload also fails the parse check below —
`jq --exit-status` reports no-output as a failure regardless of why
the input produced none — so this check is not what stands between
such a payload and acceptance. It exists for diagnostic precision: a
producer that wrote nothing and a producer that wrote garbage are
different faults with different operator remedies, and the parse
check's own diagnostic names only the garbage case.

**Args:**

- `$1` — source kind, used verbatim in every diagnostic
- `$2` — the payload
- `$3` — optional jq program emitting a message for the first field
- `$4` — optional subject, prefixed to every diagnostic as `<subject>: `.

**Exit codes:**

- `2` — the payload is empty, unparsable, or the shape program

#### payload_source_into()

Name a payload's source by kind, filling a caller variable.

The rule every caller of `require_json_payload` needs first: a source is
named by kind — the override variable's name when a fixture supplies the
payload, the API route or the config's repo-relative name otherwise — and
never by resolved path. A path in a diagnostic lets two harness scenarios
be told apart by their fixture rather than by their behavior, which is
what the census-parity gate exists to forbid.

The result is written into a caller variable rather than printed, because
a function whose result is read as `$(...)` cannot fail. In argument
position a command substitution discards its own status: the guard below
would print, the shape gate would receive an empty source name, and the
run would end 0. Filling a named variable keeps this function in the
caller's shell, where `exit` ends the script that has the problem. This
is the same reasoning the shape check above states for capturing its jq
output instead of reading it through a process substitution.

The override is resolved by indirect expansion rather than by an
environment-only lookup, so that it is seen exactly as its consumer sees it:
every caller reads its override with plain `${VAR:-}`, which sees a shell
variable as well as an exported one. A namer blind to a variable its reader
honors would name the fallback for a payload that did come from the
override.

The target is bound with a nameref rather than written with `printf -v`,
so that a caller naming one of this function's own locals collides in the
open — bash warns about the circular reference on stderr — where
`printf -v` would write the local without a word and leave the caller's
variable untouched. The locals carry a `__psrc_` prefix no call site uses,
which keeps that collision theoretical. `scripts/lib/enumerate.sh` binds
`enumerate_into`'s output the same way, so the two read alike.

**Args:**

- `$1` — name of the caller variable to fill
- `$2` — name of the override variable, exported or shell-scoped
- `$3` — source name used when the override is unset or empty

**Exit codes:**

- `2` — $2 is not a valid shell identifier

#### read_json_payload_into()

Read a file payload into a caller variable, reporting a
payload the caller could not read as a could-not-run rather than as a
finding.

The result is filled through a nameref rather than printed, for the
reason `payload_source_into` states: a reader whose value is taken as
`$(...)` cannot fail. A read that dies inside a command substitution
leaves the caller assigning an empty string under a status it does not
check, and the run continues into the shape gate, which then reports an
empty payload — or, where the caller's own reads tolerate absence, into
a drift verdict about posture nobody changed. Filling a named variable
keeps `exit 2` in the shell that has the problem.

Three conditions, three sentences: a payload that is absent, one whose
permissions forbid the read, and one whose read fails for any other
reason are different faults with different operator remedies. The third
sentence covers two guards rather than one: a directory, a FIFO, or a
device node all pass the existence and readable checks, and none of
them is something `cat` can be trusted to fail on promptly — a
directory does, but a FIFO with no writer, or a device such as
`/dev/random`, blocks or streams instead of erroring, which would turn
a could-not-run into a hang. The explicit not-a-regular-file check
below reaches that verdict by `stat`, before any read is attempted, so
the only thing left for the final `cat` guard to catch is a regular
file whose read still fails for some other reason. Both guards stay
exercisable where mode bits are no lever — none of these path kinds
depend on the permission bits `-r` already checked.

The source is named by kind, never by resolved path, exactly as
`require_json_payload` requires; pass the value `payload_source_into`
filled.

**Args:**

- `$1` — name of the caller variable to fill
- `$2` — path to read
- `$3` — source kind, used verbatim in every diagnostic
- `$4` — optional subject, prefixed to every diagnostic as `<subject>: `

**Exit codes:**

- `2` — the path is absent, unreadable, or the read failed

### scripts/lib/temp.sh

Guarded temp-file creation. Source after `set -Eeuo pipefail`.

#### make_temp()

Create a temp file or directory, reporting a failure as a
could-not-run rather than as a finding. An unwritable TMPDIR makes
`mktemp` exit 1, and an unguarded `x="$(mktemp)"` under `set -e` kills
the caller with that same 1 — the status a lint uses for "this file
carries a violation". A pre-commit hook reads that as "the tree is
stale, fix it and commit", sending the operator to edit content the
check never read. Exiting 2 from inside the command substitution
propagates through the enclosing assignment, so the call site needs no
guard of its own. No label argument: the caller's ERR trap already
prints the failing line and BASH_COMMAND, so the site names itself.

**Args:**

- `$@` — passed through to `mktemp` verbatim

**Exit codes:**

- `2` — the temp file or directory could not be created

**Stdout:**

- the created path

{% endraw %}

<!-- END scripts-reference -->
