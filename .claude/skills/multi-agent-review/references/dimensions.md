# The 8 review dimensions (hardcoded, tuned for this repo)

Fixed option set for the scoping `AskUserQuestion`. Each dimension is one
`Workflow` run: a **finder** fan-out (1–6 parallel slices, each a distinct
lens; dimension 6 batches its index entries into 3–5 finder groups) → **refute-all** stage (3 independent skeptics per finding,
default-refuted, keep if ≥2/3 survive) → survivors appended to the report.

Per-dimension option style for `AskUserQuestion` (offer these, recommend the
bolded default): **deep** (full fan-out), light (1–2 slices, headline issues
only), skip. Dimension 3 offers **adversarial** instead of deep; dimension 7 is
**advisory** only (findings always severity `advisory`).

All finder/refuter prompts are **read-only** in the sense that matters: they
must not modify the tree — no Edit/Write, no generator or formatter run that
rewrites a tracked file. Read-only **Bash is expected**, especially for refuters
doing empirical repro (`nix eval`/`build`, running a script against a crafted
input, `git show`, `yq` reads). "Read-only" bans mutation, not investigation.

Each dimension below carries a **Refuters:** paragraph — the controller injects
it verbatim as the template's `REFUTER_GUIDANCE`, which scopes the skeptic to
that dimension's claim type. The **Slices:** list is that dimension's `SLICES`.

Finder returns the structured finding schema:

```text
{ file, line, severity, claim, evidence, failure_scenario }
```

`severity ∈ {critical, high, medium, low, advisory}`. `failure_scenario` is a
concrete inputs/state → wrong-outcome the user can reproduce from the report
alone. `evidence` cites the source of truth (file:line, command output).

______________________________________________________________________

## 1. Nix flake + packaging correctness — *deep*

Slices:

- derivation/output coherence — `flake.nix`, `nix/packages.nix`, `nix/image.nix`, `nix/wrappers.nix`
- pin fetch/verify logic — `nix/pin.nix`, `nix/linpeas.nix`, `linpeas-pin.json`
- devShells + checks wiring — `nix/devshell*.nix`, `nix/checks.nix`, `nix/hooks/*`
- hammer-shim / manifest parity — `nix/hammer-shim.nix`

Refuters: verify eval behavior empirically (`nix eval`, `nix build`, `nix path-info`) — a derivation that *looks* wrong in trace often builds identically. Kill "supply-chain downgrade"-style claims unless a concrete eval reproduces them.

## 2. Shell script correctness — *deep*

Per-script logic trace across every `scripts/*.sh` (~95; size the slices from
`ls scripts/*.sh | wc -l` rather than this figure, which rots).

Slices:

- `check-*` validators
- `refresh-*` generators
- helpers / runners / everything else

Hunt: edge cases, silent failures, quoting/`set -o pipefail` gaps, `done < <(...)` process-substitution exit-swallowing, `yq | tag` conflating absent vs present-null, divergence from the behavior the header comment claims.

Refuters: reproduce the bug against the real script with a crafted input (`WORKFLOWS_DIR_OVERRIDE`/fixture). Empirical repro is the bar — keep only what actually misbehaves.

## 3. CI / supply-chain security posture — *adversarial* (strict)

Attacker-mindset agents, one per trust boundary across `.github/workflows/*` (size the slices from `ls .github/workflows/*.yml | wc -l` rather than a figure here, which rots).

Slices:

- workflow injection (untrusted input → shell/expression)
- token / permission abuse (`GITHUB_TOKEN` scope, `permissions:` blocks)
- auto-merge poisoning
- egress / allowlist gaps
- action pin integrity (SHA-pinning, tag drift)
- drift-check bypass

Refuters: refutation is mandatory and strict — skeptics default hard to refuted. Kill a claim only when a concrete attacker path fails to reproduce, not merely because it "looks" gated.

## 4. Docs accuracy — *deep*

Cross-check docs against actual code/CI/config. Flag generated docs (`refresh-*` targets, `BEGIN/END` markers) separately — drift there is a generator bug, not hand-edit. Do NOT re-run `/docs-audit`; use fresh readers here.

Slices:

- `README` + top-level (`SECURITY.md`, `CONTRIBUTING`)
- `docs/**` reference/config prose
- `CHANGELOG` vs release reality
- generated blocks (`BEGIN/END` markers, `refresh-*` output) — drift = generator bug

Refuters: `ci: gates it` ≠ prose is correct — freshness gates only generated block bodies, so a hand-written prose claim can drift while CI stays green. Kill a finding only when the doc actually matches current code/CI; keep it when the mismatch reproduces by reading both.

## 5. Test-harness quality — *deep*

Pair each `tests/*.test.sh` with the script it covers. **Seed this dimension with dimensions 2 & 6 confirmed findings** — highest-yield: a silent-pass bug is usually an untested rejection path.

Slices:

- spec-vs-characterization: does the test assert what the header comment/spec promises, or just today's output?
- mutation smell: gut a rejection clause in the covered script — does a test go red? If not, the test can't fail.
- fixture gaps + negative-fixture-per-rejection-clause coverage

Refuters: reproduce the coverage gap concretely — mutate the real script and run the real test; keep the finding only if the test stays green when it should fail. A test that *looks* weak often still catches the mutation.

## 6. Invariant ↔ enforcement coherence — *deep*

Per `docs/invariant-index.md` entry: read stated rule → read the named `enforcer`/`ci`/`hook` annotation → verdict **enforced / partial / no-op**. No-ops are high severity (repo rule: no silent no-ops in security posture).

Slices:

- batch the index entries into 3–5 groups (by enforcer kind: `ci` job, git hook, standalone `check-*` script) and give each group one finder

Refuters: run the named enforcer against a crafted violation — does it actually fail? A no-op or partial verdict survives only when the violation slips through in practice; kill it if the enforcer really catches it.

## 7. Over-engineering / simplification — *advisory* (separate report section)

Apparatus cost/value. Advisory only — the repo is intentionally maximal; never propose removing a security gate without a no-op finding backing it.

Slices:

- merge-candidate / redundant `check-*` scripts
- redundant or consolidatable workflows
- mechanisms whose enforcement hook can't watch their own source

Refuters: refute an "unnecessary" claim by finding the case the apparatus exists to catch — if a real scenario needs it, the simplification is wrong. Advisory findings still earn their place only when nothing they'd remove is load-bearing.

## 8. Update / release chain E2E — *deep*

Trace the whole chain: `bump-linpeas.sh` → `update-linpeas.yml` → `release-on-bump.yml` → `verify-latest-release.yml` / `dockerhub-sync.yml`.

Slices:

- `bump-linpeas.sh` + `update-linpeas.yml` (pin bump → PR)
- `release-on-bump.yml` (merge → release/build/sign)
- `verify-latest-release.yml` + `dockerhub-sync.yml` (post-release verify + mirror)

Refuters: hunt seam failures — races, partial-failure states, unverified handoffs, silent-green verify paths. Keep a finding only when the failed handoff reproduces from the job definitions; kill it if a later job actually re-checks the state.

______________________________________________________________________

## Cross-dimension watch-outs (from the seed run)

- Keep refuter **verdict scope consistent** with the finder's question. A dim-6-style "is this invariant enforced?" skeptic will wrongly kill a dim-2-style "is this script buggy?" finding — they answer different questions. Scope each dimension's refuter prompt to that dimension's claim type.
- Seeding later dimensions with earlier **confirmed** findings (5 ← 2/6) is the single highest-yield move.
- When a `Workflow` task-notification truncates, recover per-agent returns from the journal with `jq`, don't re-run.
- In the `Workflow` script: **no backticks inside JS template literals** (they break parsing — use string concatenation); avoid em-dash/emoji bytes in any string you later match with `Edit`.
