#!/usr/bin/env bash
# scripts/check-flake-lock-provenance.sh
#
# @description Lint: a bot `flake.lock` bump may only move
# `rev`/`narHash`/`lastModified`. Fails when a top-level input is
# added, removed, or repointed, or when any node present in both base
# and head has its source identity (owner/repo/type/url/ref/flake/...)
# changed. Gates the auto-merged weekly flake.lock update so a
# source-level repoint of an input cannot slip into the build/dev
# closure unreviewed.

# Compares the base `flake.lock` (origin/main, or BASE_LOCK_FILE)
# against the head `flake.lock` (working tree, or HEAD_LOCK_FILE),
# parsing `.nodes` with jq. Per node it compares a source-identity
# projection — `original`, the `flake` flag, and `locked` minus
# `rev`/`narHash`/`lastModified`. `inputs` wiring is intentionally
# excluded so that legitimate transitive graph churn (a dependency
# gaining or dropping an input on a routine bump) is tolerated.
#
# Scope (hybrid): a source-identity change on ANY node present in both
# base and head fails. A node add/remove fails only for TOP-LEVEL
# inputs (the entry node's `inputs`); transitive node churn is
# tolerated and logged.
#
# The entry point is each lock's own top-level `.root` field, not a
# hardcoded "root" node id — a lock's root node can be named anything.
# `.root` is validated as a string independently for base and head
# (missing or non-string is an operational error, exit 2), then
# compared for equality entirely inside the jq program via `$base.root`
# / `$head.root` — the root id is never round-tripped through a shell
# variable or passed as a jq `--arg`, so it is read byte-exact. A
# trailing newline or other control character smuggled into a node id
# cannot desync the shell's view of the root from jq's. If the base
# and head root ids differ, the check fails closed before any node
# comparison runs: a crafted lock cannot repoint `.root` at a decoy
# node to dodge the top-level comparison.
#
# Top-level input refs are resolved through `follows` paths before the
# source-identity comparison: a string ref is the target node id
# directly; an array ref is a path walked from the lock's root node
# through each node's `inputs` in turn. A ref-shape change that still
# resolves to the same source passes, while any transition that changes
# the resolved source — including string-to-array and array-to-array —
# fails.
#
# Resolution is bounded twice, and both bounds fail closed — an
# unresolvable ref is always a reported failure, never a silent pass.
#
#   * Nesting ceiling (32): each nested array ref costs one level, so a
#     cycle runs out of levels and stops. The ceiling is also a hard
#     chain-length limit on LEGAL locks: a `follows` chain nested more
#     than 32 levels deep is reported `unresolvable` even though nothing
#     about it is malformed. Real locks nest a handful of levels; a lock
#     that trips this needs the ceiling raised, not a lint bypass.
#     Both cases report `unresolvable (follows path exceeds nesting
#     ceiling)`: the resolver carries no visited set, so a cycle and an
#     over-deep legal chain are the same observation to it, and the
#     message names the bound that stopped it rather than asserting a
#     diagnosis it cannot make.
#   * Step budget (4096): total resolve steps across every top-level ref
#     of BOTH locks. The ceiling caps nesting depth but not branching
#     width, and a ref is re-resolved per path element — so depth alone
#     leaves cost exponential in lock size, and a sub-kilobyte crafted
#     lock can burn a CI runner. Exhausting the budget reports
#     `unresolvable (follows step budget exhausted)`, naming the bound
#     rather than implying the lock is malformed. It is sized to clear
#     the worst legal cost with room to spare: a chain sitting at the
#     nesting ceiling costs on the order of 560 steps per lock, since
#     every link of it is itself a top-level ref.
#
# A ref that cannot be resolved (dangling path element, cycle, empty
# array, over-deep chain, exhausted budget) fails closed, reporting which
# of the three the resolver observed: a missing node or malformed path
# element is `unresolvable (follows path names no such node)`, the two
# bounds report themselves, and the bare `unresolvable` is reserved for
# an error the resolver did not raise itself.
#
# CI coupling: the lint-doc-invariants job fetches origin/main before
# running this check. `actions/checkout` does not create
# refs/remotes/origin/main on its own. If the base lock cannot be
# resolved this script exits 2 (loud) — it never silently passes.
#
# Exit: 0 pass, 1 provenance violation, 2 operational error.
#
# Env overrides (test-only):
#   BASE_LOCK_FILE — base flake.lock path (default: git show ${BASE_REF}:flake.lock)
#   HEAD_LOCK_FILE — head flake.lock path (default: ./flake.lock)
#   BASE_REF       — git ref for base (default: origin/main)

set -Eeuo pipefail
IFS=$'\n\t'

readonly BASE_REF="${BASE_REF:-origin/main}"

function die_op() {
  printf 'flake-lock-provenance: %s\n' "$1" >&2
  exit 2
}

function load_base() {
  if [[ -n ${BASE_LOCK_FILE:-} ]]; then
    [[ -f ${BASE_LOCK_FILE} ]] || die_op "BASE_LOCK_FILE not found: ${BASE_LOCK_FILE}"
    cat -- "${BASE_LOCK_FILE}"
  else
    git show "${BASE_REF}:flake.lock" 2>/dev/null ||
      die_op "cannot resolve ${BASE_REF}:flake.lock (is origin/main fetched?)"
  fi
}

function load_head() {
  if [[ -n ${HEAD_LOCK_FILE:-} ]]; then
    [[ -f ${HEAD_LOCK_FILE} ]] || die_op "HEAD_LOCK_FILE not found: ${HEAD_LOCK_FILE}"
    cat -- "${HEAD_LOCK_FILE}"
  else
    [[ -f flake.lock ]] || die_op "flake.lock not found in working tree"
    cat -- flake.lock
  fi
}

base_json="$(load_base)"
head_json="$(load_head)"

printf '%s' "${base_json}" | jq -e '.nodes | type == "object"' >/dev/null 2>&1 ||
  die_op "base flake.lock: invalid JSON or .nodes not an object"
printf '%s' "${head_json}" | jq -e '.nodes | type == "object"' >/dev/null 2>&1 ||
  die_op "head flake.lock: invalid JSON or .nodes not an object"

function root_display() {
  # Renders `.root` for a human-readable error message ONLY — never
  # used for the equality decision or passed to jq as an --arg. @json
  # keeps control characters (e.g. a trailing newline) visible.
  printf '%s' "$1" | jq -r '.root | @json' 2>/dev/null || printf 'null'
}

printf '%s' "${base_json}" | jq -e '(.root | type) == "string"' >/dev/null 2>&1 ||
  die_op "base flake.lock: .root missing or not a string (got $(root_display "${base_json}"))"
printf '%s' "${head_json}" | jq -e '(.root | type) == "string"' >/dev/null 2>&1 ||
  die_op "head flake.lock: .root missing or not a string (got $(root_display "${head_json}"))"

# shellcheck disable=SC2016 # jq program literal; $base/$head are jq args, not shell
readonly JQ_PROG='
def srcid:
  { original: (.original // null),
    flake: (.flake // null),
    locked: ((.locked // {}) | del(.rev, .narHash, .lastModified)) };
# Names the leaf fields that differ between two srcid projections, so a
# repoint says which property moved rather than only that one did. Paths
# are dot-joined and sorted, and an absent side renders as `(absent)` so
# an added or dropped field is distinguishable from a changed value.
# `srcid` already drops rev/narHash/lastModified, so a routine bump never
# reaches here and the message stays stable across bumps.
def srcdiff($a; $b):
  [ ((([$a | paths(scalars)]) + ([$b | paths(scalars)])) | unique)[] as $p
    | select(($a | getpath($p)) != ($b | getpath($p)))
    | "\($p | join(".")): \(($a | getpath($p)) // "(absent)") -> \(($b | getpath($p)) // "(absent)")" ]
  | sort | join(", ");
# Nesting ceiling and total step budget — see the header for what each
# one bounds and why depth alone is not enough.
def follows_depth_ceiling: 32;
def follows_step_budget: 4096;
# `inputs` of a node, or {} when the node or its `inputs` is not an
# object. A crafted lock may put any JSON there; yielding {} turns that
# into a dangling-path failure instead of a raw jq type error.
def inputs_of($node):
  if ($node | type) == "object" and (($node.inputs | type) == "object")
  then $node.inputs
  else {}
  end;
# Resolves one input ref to a node id, threading the remaining step
# budget through every recursion. Returns { node, left }; raises
# { budget, reason, left } so a caught failure still reports the steps it
# spent and which bound or malformation stopped it, and the budget stays
# global rather than per-ref.
def resolve($lock; $origin; $ref; $depth; $left):
  if $left <= 0 then error({ budget: true, reason: "budget", left: 0 })
  else ($left - 1) as $rem
  | if $depth > follows_depth_ceiling
    then error({ budget: false, reason: "ceiling", left: $rem })
    elif ($ref | type) == "string" then { node: $ref, left: $rem }
    elif ($ref | type) == "array" then
      if ($ref | length) == 0 then error({ budget: false, reason: "nonode", left: $rem })
      else reduce $ref[] as $e ({ node: $origin, left: $rem };
        . as $st
        | if ($e | type) != "string" then error({ budget: false, reason: "nonode", left: $st.left }) else . end
        | ($lock.nodes[$st.node] // error({ budget: false, reason: "nonode", left: $st.left })) as $node
        | (inputs_of($node)[$e] // error({ budget: false, reason: "nonode", left: $st.left })) as $next
        | resolve($lock; $origin; $next; $depth + 1; $st.left))
      end
    else error({ budget: false, reason: "nonode", left: $rem })
    end
  end;
# Never-raising wrapper: on failure the node is null, `exhausted` says
# whether the step budget ran out, and `reason` names what the resolver
# observed. An error value that is not one of ours cannot report what it
# spent, so it forfeits the rest of the budget — every later ref then
# fails closed too — and reports `unknown`, which keeps its message
# generic rather than claiming a diagnosis the resolver did not make.
def try_resolve($lock; $origin; $ref; $left):
  try (resolve($lock; $origin; $ref; 0; $left) + { exhausted: false, reason: "ok" })
  catch (if (type == "object") and has("left")
         then { node: null, left: .left, exhausted: (.budget == true),
                reason: (.reason // "unknown") }
         else { node: null, left: 0, exhausted: false, reason: "unknown" }
         end);
# The base/head root-id comparison happens HERE, on $base.root /
# $head.root as parsed by jq — never on a shell variable. A node id
# is an arbitrary JSON string; only jq (not a bash `$( )` capture,
# which strips all trailing newlines) can compare it byte-exact.
if ($base.root != $head.root) then
  { fails: ["FAIL: root node id changed: \($base.root) -> \($head.root)"],
    notes: [],
    root_mismatch: true }
else
($base.root) as $broot
| ($head.root) as $hroot
| ($base.nodes[$broot].inputs // {}) as $bin
| ($head.nodes[$hroot].inputs // {}) as $hin
| ($bin | keys) as $bk
| ($hin | keys) as $hk
| [ ($hk - $bk)[] | "FAIL: top-level input added: \(.)" ] as $added
| [ ($bk - $hk)[] | "FAIL: top-level input removed: \(.)" ] as $removed
| [ $bk[] | select(. as $n | $hk | index($n)) ] as $common
# One fold over the shared top-level inputs, carrying the step budget
# left over from the previous input — base and head both draw on it, so
# the whole comparison costs a bounded number of resolve steps no
# matter how the locks branch.
| (reduce $common[] as $name ({ left: follows_step_budget, fails: [] };
    . as $acc
    | try_resolve($base; $broot; $bin[$name]; $acc.left) as $bres
    | try_resolve($head; $hroot; $hin[$name]; $bres.left) as $hres
    | { left: $hres.left,
        fails: ($acc.fails + (
          if ($bres.exhausted or $hres.exhausted)
          then ["FAIL: top-level input unresolvable (follows step budget exhausted): \($name)"]
          elif ($bres.node == null) or ($hres.node == null)
            or (($base.nodes | has($bres.node)) | not)
            or (($head.nodes | has($hres.node)) | not)
          then (if ([$bres.reason, $hres.reason] | any(. == "ceiling"))
                then ["FAIL: top-level input unresolvable (follows path exceeds nesting ceiling): \($name)"]
                elif ([$bres.reason, $hres.reason] | any(. == "unknown"))
                then ["FAIL: top-level input unresolvable: \($name)"]
                else ["FAIL: top-level input unresolvable (follows path names no such node): \($name)"]
                end)
          elif ($base.nodes[$bres.node] | srcid) != ($head.nodes[$hres.node] | srcid)
          then ["FAIL: top-level input repointed: \($name)"]
          else []
          end)) })
   | .fails) as $tlrep
| [ ($base.nodes | keys[])
    | select(. != $broot)
    | . as $k
    | select($head.nodes | has($k))
    | select(($base.nodes[$k] | srcid) != ($head.nodes[$k] | srcid))
    | "FAIL: node repointed: \($k) (\(srcdiff($base.nodes[$k] | srcid; $head.nodes[$k] | srcid)))" ] as $noderep
| [ ($head.nodes | keys[]) | select(. != $hroot) | . as $k
    | select(($base.nodes | has($k)) | not)
    | "note: transitive node added (tolerated): \($k)" ] as $tadd
| [ ($base.nodes | keys[]) | select(. != $broot) | . as $k
    | select(($head.nodes | has($k)) | not)
    | "note: transitive node removed (tolerated): \($k)" ] as $trem
| { fails: ($added + $removed + $tlrep + $noderep),
    notes: ($tadd + $trem),
    root_mismatch: false }
end
'

jq_err_file="$(mktemp)"
trap 'rm --force -- "${jq_err_file}"' EXIT

if ! result="$(jq -n \
  --argjson base "${base_json}" \
  --argjson head "${head_json}" \
  "${JQ_PROG}" 2>"${jq_err_file}")"; then
  die_op "flake.lock comparison failed: $(cat -- "${jq_err_file}")"
fi

notes="$(printf '%s' "${result}" | jq -r '.notes[]')"
fails="$(printf '%s' "${result}" | jq -r '.fails[]')"
root_mismatch="$(printf '%s' "${result}" | jq -r '.root_mismatch')"

if [[ -n ${notes} ]]; then
  printf '%s\n' "${notes}" >&2
fi

if [[ -n ${fails} ]]; then
  printf '%s\n' "${fails}" >&2
  if [[ ${root_mismatch} == "true" ]]; then
    printf 'flake.lock provenance check FAILED — the lock entry point was repointed.\n' >&2
    printf 'A routine bump never renames the root node. Review the change.\n' >&2
  else
    printf 'flake.lock provenance check FAILED — an input source identity changed.\n' >&2
    printf 'A routine bump may only move rev/narHash/lastModified. Review the change.\n' >&2
  fi
  exit 1
fi

printf 'flake.lock provenance OK\n'
