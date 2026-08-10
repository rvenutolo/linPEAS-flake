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
# through each node's `inputs` in turn (cycle-guarded by a depth
# limit). A ref-shape change that still resolves to the same source
# passes, while any transition that changes the resolved source —
# including string-to-array and array-to-array — fails. A ref that
# cannot be resolved (dangling path element, cycle, empty array) fails
# closed.
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
def resolve($lock; $origin; $ref; $depth):
  if $depth > 32 then error("follows depth exceeded")
  elif ($ref | type) == "string" then $ref
  elif ($ref | type) == "array" then
    if ($ref | length) == 0 then error("empty follows path")
    else reduce $ref[] as $e ($origin;
      . as $cur
      | ($lock.nodes[$cur] // error("missing node: \($cur)")) as $node
      | (($node.inputs // {})[$e] // error("dangling follows: \($e) from \($cur)")) as $next
      | resolve($lock; $origin; $next; $depth + 1))
    end
  else error("bad input ref type: \($ref | type)")
  end;
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
| [ $bk[]
    | select(. as $n | $hk | index($n))
    | . as $name
    | $bin[$name] as $bref | $hin[$name] as $href
    | (try resolve($base; $broot; $bref; 0) catch null) as $bnode
    | (try resolve($head; $hroot; $href; 0) catch null) as $hnode
    | if ($bnode == null) or ($hnode == null)
        or (($base.nodes | has($bnode)) | not)
        or (($head.nodes | has($hnode)) | not)
      then "FAIL: top-level input unresolvable: \($name)"
      elif ($base.nodes[$bnode] | srcid) != ($head.nodes[$hnode] | srcid)
      then "FAIL: top-level input repointed: \($name)"
      else empty
      end ] as $tlrep
| [ ($base.nodes | keys[])
    | select(. != $broot)
    | . as $k
    | select($head.nodes | has($k))
    | select(($base.nodes[$k] | srcid) != ($head.nodes[$k] | srcid))
    | "FAIL: node repointed: \($k)" ] as $noderep
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
