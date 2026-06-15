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
# inputs (root.inputs); transitive node churn is tolerated and logged.
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

# shellcheck disable=SC2016 # jq program literal; $base/$head are jq args, not shell
readonly JQ_PROG='
def srcid:
  { original: (.original // null),
    flake: (.flake // null),
    locked: ((.locked // {}) | del(.rev, .narHash, .lastModified)) };
($base.nodes.root.inputs // {}) as $bin
| ($head.nodes.root.inputs // {}) as $hin
| ($bin | keys) as $bk
| ($hin | keys) as $hk
| [ ($hk - $bk)[] | "FAIL: top-level input added: \(.)" ] as $added
| [ ($bk - $hk)[] | "FAIL: top-level input removed: \(.)" ] as $removed
| [ $bk[]
    | select(. as $n | $hk | index($n))
    | . as $name
    | $bin[$name] as $bn | $hin[$name] as $hn
    | select(($bn | type) == "string" and ($hn | type) == "string")
    | select(($base.nodes[$bn] | srcid) != ($head.nodes[$hn] | srcid))
    | "FAIL: top-level input repointed: \($name)" ] as $tlrep
| [ ($base.nodes | keys[])
    | select(. != "root")
    | . as $k
    | select($head.nodes | has($k))
    | select(($base.nodes[$k] | srcid) != ($head.nodes[$k] | srcid))
    | "FAIL: node repointed: \($k)" ] as $noderep
| [ ($head.nodes | keys[]) | select(. != "root") | . as $k
    | select(($base.nodes | has($k)) | not)
    | "note: transitive node added (tolerated): \($k)" ] as $tadd
| [ ($base.nodes | keys[]) | select(. != "root") | . as $k
    | select(($head.nodes | has($k)) | not)
    | "note: transitive node removed (tolerated): \($k)" ] as $trem
| { fails: ($added + $removed + $tlrep + $noderep),
    notes: ($tadd + $trem) }
'

result="$(jq -n \
  --argjson base "${base_json}" \
  --argjson head "${head_json}" \
  "${JQ_PROG}")"

notes="$(printf '%s' "${result}" | jq -r '.notes[]')"
fails="$(printf '%s' "${result}" | jq -r '.fails[]')"

if [[ -n ${notes} ]]; then
  printf '%s\n' "${notes}" >&2
fi

if [[ -n ${fails} ]]; then
  printf '%s\n' "${fails}" >&2
  printf 'flake.lock provenance check FAILED — an input source identity changed.\n' >&2
  printf 'A routine bump may only move rev/narHash/lastModified. Review the change.\n' >&2
  exit 1
fi

printf 'flake.lock provenance OK\n'
