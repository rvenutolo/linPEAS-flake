#!/usr/bin/env bash
# scripts/check-flake-lock-provenance.sh
#
# @description Lint: a `flake.lock` bump that `flake.nix` does not
# account for may only move `rev`/`narHash`/`lastModified`. Fails when a
# top-level input is added, removed, or repointed, or when any node
# present in both base and head has its source identity
# (owner/repo/type/url/ref/flake/...) changed, unless `flake.nix` itself
# declares a different `url` for that input between base and head.
# Gates the auto-merged weekly flake.lock update so a source-level
# repoint of an input cannot slip into the build/dev closure
# undeclared.

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
# Corroboration by `flake.nix`: a move is a violation only when nothing
# declared it. The bot path this gate bounds — the weekly
# `update-flake-lock.yml` cron — rewrites `flake.lock` alone and never
# edits `flake.nix`, so on that path both sides parse to the same
# input->url map and every move still fails. When `flake.nix` DOES
# declare a different `url` for an input across base and head, that
# input's lock move is the declared consequence rather than a smuggled
# one: it is tolerated and logged as a note naming both the input and
# the `flake.nix` move that vouched for it. Corroboration is per input
# name, so a PR that legitimately repoints one input cannot carry an
# undeclared repoint of another. Only top-level inputs are reachable —
# `flake.nix` names no transitive node, so a transitive repoint is never
# corroborated and stays gated exactly as before.
#
# What corroboration deliberately does NOT do is verify that the lock's
# new `original` is the one `nix` would derive from the new `flake.nix`
# url. That equivalence is `flake-check`'s to enforce, and it does:
# a lock disagreeing with `flake.nix` fails evaluation. Re-deriving a
# flake reference from a url string here would duplicate that check
# against a hand-written parser, and a parser that drifted would block
# legitimate bumps while claiming provenance grounds.
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
#   BASE_FLAKE_NIX — base flake.nix path (default: git show ${BASE_REF}:flake.nix)
#   HEAD_FLAKE_NIX — head flake.nix path (default: ./flake.nix)
#   BASE_REF       — git ref for base (default: origin/main)

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/payload.sh
source "${_lib_dir}/lib/payload.sh"

# Every lock read below goes through `jq`. Absent, it ends the run
# under exit 127 with no sentence naming the tool, and the shape
# probes further down would report the lock as malformed instead.
require_tool jq

readonly BASE_REF="${BASE_REF:-origin/main}"

function die_op() {
  printf 'flake-lock-provenance: %s\n' "$1" >&2
  exit 2
}

# The base payload is either a fixture path (BASE_LOCK_FILE) or the
# base ref's flake.lock read via `git show` — a git-object read, not a
# file read, so it stays outside read_json_payload_into's could-not-run
# guards and keeps its own die_op, naming the source by kind rather than
# reconstructing the ref string a second time.
payload_source_into base_source BASE_LOCK_FILE "${BASE_REF}:flake.lock"
readonly base_source
if [[ -n ${BASE_LOCK_FILE:-} ]]; then
  read_json_payload_into base_json "${BASE_LOCK_FILE}" "${base_source}"
else
  base_json="$(git show "${BASE_REF}:flake.lock" 2>/dev/null)" ||
    die_op "cannot resolve ${base_source} (is origin/main fetched?)"
fi
readonly base_json

# The head payload is always a file read — either HEAD_LOCK_FILE or the
# working tree's own flake.lock — so one read_json_payload_into call
# covers both arms; the override and the default differ only in which
# path it reads.
#
# This read carries a subject and the base read above carries none,
# which is the naming rule rather than an inconsistency: on a live run
# this one names its source `flake.lock`, the same kind
# check-pre-commit-hooks-sha-parity.sh names for the lock it reads,
# while the base read names `<base ref>:flake.lock`, which nothing else
# in this tree produces.
readonly head_path="${HEAD_LOCK_FILE:-flake.lock}"
payload_source_into head_source HEAD_LOCK_FILE 'flake.lock'
readonly head_source
read_json_payload_into head_json "${head_path}" "${head_source}" \
  'flake-lock provenance head'
readonly head_json

# Renders `flake.nix`'s top-level `inputs` block as a JSON object
# mapping each input name to its declared `url` string. An input
# declared without a `url` (a bare top-level `follows`) is absent from
# the map, which reads the same as "this input declares no source" and
# so never corroborates a lock repoint.
#
# The parser recognises the two shapes nixfmt produces, and only those:
#
#   <name>.url = "<url>";
#   <name> = { url = "<url>"; ... };
#
# A nested `inputs.<name>.url` line inside a block is deliberately not
# matched — the `url =` pattern is anchored at the start of the line, so
# a nested input's source cannot be read as a top-level declaration.
#
# Brace depth is tracked across the `inputs` block to tell those two
# shapes apart; whole-line comments are skipped so a `{` inside one
# cannot desync the depth. A file with no `inputs` block at all is an
# operational error rather than an empty map: an empty map silently
# corroborates nothing, which would turn a parser that stopped working
# into a gate that blocks every legitimate bump with a message naming
# the wrong cause.
# @arg $1 name of the variable to assign  @arg $2 flake.nix content
# @arg $3 human-readable source name for error messages
function flake_inputs_into() {
  local -n _out="$1"
  local -r content="$2" source_name="$3"
  local line depth=0 in_inputs=0 seen_inputs=0 block='' braces
  local -a args=()
  while IFS= read -r line; do
    [[ ${line} =~ ^[[:space:]]*# ]] && continue
    if ((in_inputs == 0)); then
      if ((seen_inputs == 0)) && [[ ${line} =~ ^[[:space:]]*inputs[[:space:]]*=[[:space:]]*\{ ]]; then
        in_inputs=1
        seen_inputs=1
        depth=1
      fi
      continue
    fi
    if ((depth == 1)); then
      if [[ ${line} =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_-]*)\.url[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]]; then
        args+=(--arg "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")
      elif [[ ${line} =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_-]*)[[:space:]]*=[[:space:]]*\{ ]]; then
        block="${BASH_REMATCH[1]}"
      fi
    elif ((depth == 2)) && [[ -n ${block} ]] &&
      [[ ${line} =~ ^[[:space:]]*url[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]]; then
      args+=(--arg "${block}" "${BASH_REMATCH[1]}")
    fi
    braces="${line//[^\{]/}"
    depth=$((depth + ${#braces}))
    braces="${line//[^\}]/}"
    depth=$((depth - ${#braces}))
    if ((depth <= 1)); then block=''; fi
    if ((depth <= 0)); then in_inputs=0; fi
  done <<<"${content}"
  if ((seen_inputs == 0)); then
    die_op "${source_name}: no top-level 'inputs = {' block found"
  fi
  _out="$(jq -n "${args[@]}" '$ARGS.named')"
}

# `flake.nix` is read on both sides for the same reason the lock is: a
# repoint of an input's source is a provenance violation ONLY when
# nothing declared it. The weekly `update-flake-lock.yml` cron — the bot
# path this gate exists to bound — rewrites the lock alone and never
# touches `flake.nix`, so under that path the two maps are identical and
# every repoint still fails exactly as before.
payload_source_into base_nix_source BASE_FLAKE_NIX "${BASE_REF}:flake.nix"
readonly base_nix_source
if [[ -n ${BASE_FLAKE_NIX:-} ]]; then
  read_json_payload_into base_nix_text "${BASE_FLAKE_NIX}" "${base_nix_source}"
else
  base_nix_text="$(git show "${BASE_REF}:flake.nix" 2>/dev/null)" ||
    die_op "cannot resolve ${base_nix_source} (is origin/main fetched?)"
fi
readonly base_nix_text

readonly head_nix_path="${HEAD_FLAKE_NIX:-flake.nix}"
payload_source_into head_nix_source HEAD_FLAKE_NIX 'flake.nix'
readonly head_nix_source
read_json_payload_into head_nix_text "${head_nix_path}" "${head_nix_source}" \
  'flake-lock provenance head flake.nix'
readonly head_nix_text

flake_inputs_into base_nix_json "${base_nix_text}" "${base_nix_source}"
readonly base_nix_json
flake_inputs_into head_nix_json "${head_nix_text}" "${head_nix_source}"
readonly head_nix_json

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
# True when `flake.nix` itself declares a different source for $name
# between base and head. That declaration is what separates a repoint
# somebody asked for from one that appeared in the lock alone: the
# lock-only bot path never edits `flake.nix`, so under it both sides
# read the same and this is false for every input. A transitive node is
# named in neither map, so `null != null` keeps it strictly gated —
# corroboration reaches top-level inputs only, which are exactly the
# names `flake.nix` declares.
def corroborated($name):
  ($nixbase[$name] // null) != ($nixhead[$name] // null);
# Renders the `flake.nix` side of a corroborated move, so the note says
# which declaration vouched for the lock rather than only that one did.
def nixmove($name):
  "\($nixbase[$name] // "(absent)") -> \($nixhead[$name] // "(absent)")";
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
# budget through every recursion. Returns { node, left, depth }, where
# `depth` is the deepest nesting level the walk reached — the headroom
# left under the ceiling is what tells an operator whether a legal lock
# is about to need the ceiling raised. Raises { budget, reason, left } so
# a caught failure still reports the steps it spent and which bound or
# malformation stopped it, and the budget stays global rather than
# per-ref.
def resolve($lock; $origin; $ref; $depth; $left):
  if $left <= 0 then error({ budget: true, reason: "budget", left: 0 })
  else ($left - 1) as $rem
  | if $depth > follows_depth_ceiling
    then error({ budget: false, reason: "ceiling", left: $rem })
    elif ($ref | type) == "string" then { node: $ref, left: $rem, depth: $depth }
    elif ($ref | type) == "array" then
      if ($ref | length) == 0 then error({ budget: false, reason: "nonode", left: $rem })
      else reduce $ref[] as $e ({ node: $origin, left: $rem, depth: $depth };
        . as $st
        | if ($e | type) != "string" then error({ budget: false, reason: "nonode", left: $st.left }) else . end
        | ($lock.nodes[$st.node] // error({ budget: false, reason: "nonode", left: $st.left })) as $node
        | (inputs_of($node)[$e] // error({ budget: false, reason: "nonode", left: $st.left })) as $next
        | resolve($lock; $origin; $next; $depth + 1; $st.left) as $sub
        | $sub + { depth: ([$sub.depth, $st.depth] | max) })
      end
    else error({ budget: false, reason: "nonode", left: $rem })
    end
  end;
# Never-raising wrapper: on failure the node is null, `exhausted` says
# whether the step budget ran out, and `reason` names what the resolver
# observed. An error value that is not one of ours cannot report what it
# spent, so it forfeits the rest of the budget — every later ref then
# fails closed too — and reports `unknown`, which keeps its message
# generic rather than claiming a diagnosis the resolver did not make. A
# failed walk reports depth 0: it reached no depth worth vouching for.
def try_resolve($lock; $origin; $ref; $left):
  try (resolve($lock; $origin; $ref; 0; $left) + { exhausted: false, reason: "ok" })
  catch (if (type == "object") and has("left")
         then { node: null, left: .left, exhausted: (.budget == true),
                reason: (.reason // "unknown"), depth: 0 }
         else { node: null, left: 0, exhausted: false, reason: "unknown", depth: 0 }
         end);
# The base/head root-id comparison happens HERE, on $base.root /
# $head.root as parsed by jq — never on a shell variable. A node id
# is an arbitrary JSON string; only jq (not a bash `$( )` capture,
# which strips all trailing newlines) can compare it byte-exact.
if ($base.root != $head.root) then
  { fails: ["FAIL: root node id changed: \($base.root) -> \($head.root)"],
    notes: [],
    summary: "",
    root_mismatch: true }
else
($base.root) as $broot
| ($head.root) as $hroot
| ($base.nodes[$broot].inputs // {}) as $bin
| ($head.nodes[$hroot].inputs // {}) as $hin
| ($bin | keys) as $bk
| ($hin | keys) as $hk
| [ ($hk - $bk)[] | select(corroborated(.) | not) | "FAIL: top-level input added: \(.)" ] as $added
| [ ($bk - $hk)[] | select(corroborated(.) | not) | "FAIL: top-level input removed: \(.)" ] as $removed
| [ (($hk - $bk) + ($bk - $hk))[] | select(corroborated(.))
    | "note: top-level input add/remove corroborated by flake.nix (tolerated): \(.) (\(nixmove(.)))" ] as $addrem_ok
| [ $bk[] | select(. as $n | $hk | index($n)) ] as $common
# One fold over the shared top-level inputs, carrying the step budget
# left over from the previous input — base and head both draw on it, so
# the whole comparison costs a bounded number of resolve steps no
# matter how the locks branch.
| (reduce $common[] as $name ({ left: follows_step_budget, fails: [], depth: 0 };
    . as $acc
    | try_resolve($base; $broot; $bin[$name]; $acc.left) as $bres
    | try_resolve($head; $hroot; $hin[$name]; $bres.left) as $hres
    | { left: $hres.left,
        depth: ([$acc.depth, $bres.depth, $hres.depth] | max),
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
          then (if corroborated($name) then []
                else ["FAIL: top-level input repointed: \($name)"
                      + (if $bres.node != $hres.node
                         then " (\($bres.node) -> \($hres.node))"
                         else "" end)]
                end)
          else []
          end)) })
   ) as $tlacc
| ($tlacc.fails) as $tlrep
| [ ($base.nodes | keys[])
    | select(. != $broot)
    | . as $k
    | select($head.nodes | has($k))
    | select(($base.nodes[$k] | srcid) != ($head.nodes[$k] | srcid))
    | select(corroborated($k) | not)
    | "FAIL: node repointed: \($k) (\(srcdiff($base.nodes[$k] | srcid; $head.nodes[$k] | srcid)))" ] as $noderep
| [ ($base.nodes | keys[])
    | select(. != $broot)
    | . as $k
    | select($head.nodes | has($k))
    | select(($base.nodes[$k] | srcid) != ($head.nodes[$k] | srcid))
    | select(corroborated($k))
    | "note: node repoint corroborated by flake.nix (tolerated): \($k) (\(nixmove($k)))" ] as $noderep_ok
| [ ($head.nodes | keys[]) | select(. != $hroot) | . as $k
    | select(($base.nodes | has($k)) | not)
    | "note: transitive node added (tolerated): \($k)" ] as $tadd
| [ ($base.nodes | keys[]) | select(. != $broot) | . as $k
    | select(($head.nodes | has($k)) | not)
    | "note: transitive node removed (tolerated): \($k)" ] as $trem
# Scope of the clean verdict. A ref counts as resolved through `follows`
# when either side states it as a path, since that is the side the
# resolver had to walk. The entry point is rendered with @json so a node
# id carrying control characters stays visible and stays on one line.
| ([ $common[] | . as $n
     | select((($bin[$n] | type) == "array") or (($hin[$n] | type) == "array")) ]
   | length) as $viafollows
| ([ ($base.nodes | keys[]) | . as $k
     | select($k != $broot) | select($head.nodes | has($k)) ]
   | length) as $shared
| ($addrem_ok + $noderep_ok) as $corroborated
| { fails: ($added + $removed + $tlrep + $noderep),
    notes: ($tadd + $trem + $corroborated),
    summary: ("entry \($base.root | @json); top-level inputs resolved: \($common | length) (\($viafollows) via follows, max depth \($tlacc.depth)); shared nodes compared: \($shared); transitive churn tolerated: \($tadd | length) added, \($trem | length) removed; flake.nix-corroborated moves: \($corroborated | length)"),
    root_mismatch: false }
end
'

jq_err_file="$(make_temp)"
trap 'rm --force -- "${jq_err_file}"' EXIT

if ! result="$(jq -n \
  --argjson base "${base_json}" \
  --argjson head "${head_json}" \
  --argjson nixbase "${base_nix_json}" \
  --argjson nixhead "${head_nix_json}" \
  "${JQ_PROG}" 2>"${jq_err_file}")"; then
  die_op "flake.lock comparison failed: $(cat -- "${jq_err_file}")"
fi

notes="$(printf '%s' "${result}" | jq -r '.notes[]')"
fails="$(printf '%s' "${result}" | jq -r '.fails[]')"
root_mismatch="$(printf '%s' "${result}" | jq -r '.root_mismatch')"
summary="$(printf '%s' "${result}" | jq -r '.summary')"

if [[ -n ${notes} ]]; then
  printf '%s\n' "${notes}" >&2
fi

if [[ -n ${fails} ]]; then
  printf '%s\n' "${fails}" >&2
  if [[ ${root_mismatch} == "true" ]]; then
    printf 'flake.lock provenance check FAILED — the lock entry point was repointed.\n' >&2
    printf 'A routine bump never renames the root node. Review the change.\n' >&2
  else
    printf 'flake.lock provenance check FAILED — an undeclared input source identity changed.\n' >&2
    printf 'A bump flake.nix does not declare may only move rev/narHash/lastModified.\n' >&2
    printf 'Repoint the input in flake.nix too, or review the change.\n' >&2
  fi
  exit 1
fi

printf 'flake.lock provenance OK: %s\n' "${summary}"
