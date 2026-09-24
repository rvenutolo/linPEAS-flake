---
description: Fix pass for a docs-audit findings report — ledgered, gated, checked before the PR opens
---

Work the findings report named in the argument using the `docs-audit-fix`
skill. Invoke that skill and follow it exactly: branch, ledger each
rewritten paragraph against its artifact, clear every sibling set, dispatch
a separate gate agent, re-gate every fix it forces, and open the PR only
when `check-fix-ledger.sh` exits 0.

If no report path is given, use the newest
`.claude/reports/*-docs-correctness-findings*.md` and say which one.

$ARGUMENTS
