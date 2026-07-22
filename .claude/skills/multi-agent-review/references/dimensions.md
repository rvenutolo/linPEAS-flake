# The 8 review dimensions (hardcoded, tuned for this repo)

Fixed option set for the scoping `AskUserQuestion`. Each dimension is one
`Workflow` run: a **finder** fan-out (4–7 parallel slices, each a distinct
lens) → **refute-all** stage (3 independent skeptics per finding,
default-refuted, keep if ≥2/3 survive) → survivors appended to the report.

Per-dimension option style for `AskUserQuestion` (offer these, recommend the
bolded default): **deep** (full fan-out), light (1–2 slices, headline issues
only), skip. Dimension 3 offers **adversarial** instead of deep; dimension 7 is
**advisory** only (findings always severity `advisory`).

All finder/refuter subagent prompts are **read-only**: no Edit/Write/Bash
mutation, review only. Finder returns the structured finding schema:

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

Per-script logic trace across `scripts/*.sh` (~70). Batch by family: `check-*`, `refresh-*`, helpers/runners. Hunt: edge cases, silent failures, quoting/`set -o pipefail` gaps, `done < <(...)` process-substitution exit-swallowing, `yq | tag` conflating absent vs present-null, divergence from the behavior the header comment claims.

Refuters: reproduce the bug against the real script with a crafted input (`WORKFLOWS_DIR_OVERRIDE`/fixture). Empirical repro is the bar — keep only what actually misbehaves.

## 3. CI / supply-chain security posture — *adversarial* (strict)

Attacker-mindset agents per trust boundary across `.github/workflows/*` (~29): workflow injection, token/permission abuse, auto-merge poisoning, egress/allowlist gaps, pin integrity, drift-check bypass. Refutation is mandatory and strict (skeptics default hard to refuted).

## 4. Docs accuracy — *fresh agents*

Cross-check `README`, `docs/**`, `SECURITY.md`, `CONTRIBUTING`, `CHANGELOG` against actual code/CI/config. Flag generated docs (`refresh-*` targets, `BEGIN/END` markers) separately — drift there is a generator bug, not hand-edit. Do NOT re-run `/docs-audit`; use fresh readers here. `ci: gates it` ≠ prose is correct (freshness gates only generated block bodies).

## 5. Test-harness quality — *deep*

Pair each `tests/*.test.sh` with the script it covers: does it assert the *spec* (not characterization), *can it fail* (mutation smell — gut the rejection clause, does a test go red?), fixture gaps, negative-fixture-per-rejection-clause coverage. **Seed this dimension with dimensions 2 & 6 confirmed findings** — highest-yield: a silent-pass bug is usually an untested rejection path.

## 6. Invariant ↔ enforcement coherence — *deep*

Per `docs/invariant-index.md` entry: read stated rule → read the named `enforcer`/`ci`/`hook` annotation → verdict **enforced / partial / no-op**. No-ops are high severity (repo rule: no silent no-ops in security posture).

## 7. Over-engineering / simplification — *advisory* (separate report section)

Apparatus cost/value: merge-candidate checks, redundant workflows, consolidation opportunities, mechanisms whose enforcement hook can't watch their own source. Advisory only — the repo is intentionally maximal; never propose removing a security gate without a no-op finding backing it.

## 8. Update / release chain E2E — *deep*

Trace the whole chain: `bump-linpeas.sh` → `update-linpeas.yml` → `release-on-bump.yml` → `verify-latest-release.yml` / `dockerhub-sync.yml`. Hunt seam failures: races, partial-failure states, unverified handoffs between jobs, silent-green verify paths.

______________________________________________________________________

## Cross-dimension watch-outs (from the seed run)

- Keep refuter **verdict scope consistent** with the finder's question. A dim-6-style "is this invariant enforced?" skeptic will wrongly kill a dim-2-style "is this script buggy?" finding — they answer different questions. Scope each dimension's refuter prompt to that dimension's claim type.
- Seeding later dimensions with earlier **confirmed** findings (5 ← 2/6) is the single highest-yield move.
- When a `Workflow` task-notification truncates, recover per-agent returns from the journal with `jq`, don't re-run.
- In the `Workflow` script: **no backticks inside JS template literals** (they break parsing — use string concatenation); avoid em-dash/emoji bytes in any string you later match with `Edit`.
