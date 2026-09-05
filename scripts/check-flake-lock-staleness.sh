#!/usr/bin/env bash
# scripts/check-flake-lock-staleness.sh
#
# @description Lint: every top-level `flake.lock` input was refreshed
# recently enough that the mechanism responsible for refreshing it is
# demonstrably still running. Fails when an input's `locked.lastModified`
# is older than the threshold declared for it.

# What this guards is mechanism liveness, not upstream freshness. Two
# things refresh this repo's inputs — the weekly `update-flake-lock.yml`
# cron (`nix flake update`, which re-resolves every branch-tracked
# input) and Renovate (the only thing that can move a rev-pinned one) —
# and neither announces having stopped. A disabled workflow, a broken
# trigger, a manager that stops opening PRs: each leaves the inputs the
# affected mechanism refreshes frozen while every check stays green. The
# latter two — a broken trigger and a manager that stops opening PRs —
# are live risks here.
#
# `locked.lastModified` is an UPSTREAM commit time, not a "when did we
# last check" timestamp, which is what makes the thresholds below
# uneven rather than arbitrary. For a high-churn input, upstream moves
# far faster than the threshold, so an old lock can only mean nobody
# refreshed it — age is a sharp liveness signal. For a low-churn input,
# an old lock much more likely means upstream is quiet, and a tight
# threshold would report that as drift. Each input therefore gets the
# threshold its upstream churn can actually support:
#
#   * FAST (14 days) — branch-tracked against an upstream that commits
#     at least daily. Two missed weekly cron cycles is already past
#     anything a healthy mechanism produces.
#   * SLOW (120 days) — everything else. Loose enough that ordinary
#     upstream quiet never fires it, tight enough that a mechanism that
#     has genuinely stopped still surfaces. A rev-pinned input such as
#     `pre-commit-hooks` can sit months past a manager that has gone
#     quiet, so the bound is set to catch that class without calling a
#     quiet upstream a fault.
#
# Scope is the TOP-LEVEL inputs — the entry node's `inputs` — and only
# those. A transitive node's rev is chosen by its parent's pin, not by
# anything this repo runs, so its age reports on somebody else's
# release cadence: `flake-compat` moves only when `git-hooks.nix`
# repins it, and no mechanism here is failing. Including it would
# mean a check that goes red on somebody else's quiet, which nobody
# here can act on.
#
# An input present in the lock that the table below does not name is an
# operational error, not a pass. A threshold table is exactly the kind
# of thing that rots when an input is added, and the silent-pass
# version of that rot is a new input nobody is watching.
#
# Exit: 0 every input fresh, 1 one or more stale, 2 operational error.
#
# Env overrides (test-only):
#   FLAKE_LOCK_OVERRIDE — path to the flake.lock to read
#   STALENESS_NOW_EPOCH — unix seconds to treat as "now"; the harness
#                         sets it so a fixture's verdict cannot drift
#                         with the wall clock

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/payload.sh
source "${_lib_dir}/lib/payload.sh"

readonly SECONDS_PER_DAY=86400
readonly FAST_DAYS=14
readonly SLOW_DAYS=120

# Threshold per top-level input, in days. Keyed by the input name as it
# appears in the entry node's `inputs`. Adding an input to `flake.nix`
# without adding it here is a could-not-run, by design.
#
# Every subscript is quoted. An unquoted one is parsed as an arithmetic
# expression, so `[flake-parts]` is read as a subtraction and stored
# under key `0` — and `shfmt` reformats it to `[flake - parts]` to match
# that reading, which is how the mistake announces itself. The quotes
# are load-bearing, not style.
declare -rA THRESHOLD_DAYS=(
  # Branch-tracked, refreshed by the weekly update-flake-lock cron.
  # nixos-unstable moves several times a day and the stable branch takes
  # backports continuously, so neither can sit two weeks untouched
  # unless the cron stopped.
  ["nixpkgs"]="${FAST_DAYS}"
  ["nixpkgs-unstable"]="${FAST_DAYS}"
  # Branch-tracked and refreshed by the same cron, but upstream commits
  # in bursts with quiet stretches between, so these carry the loose
  # bound. nixpkgs above is the sharp detector for that cron; these are
  # backstops for the case where it somehow refreshes those two alone.
  ["flake-parts"]="${SLOW_DAYS}"
  ["treefmt-nix"]="${SLOW_DAYS}"
  # Rev-pinned in flake.nix, so `nix flake update` cannot move it and
  # Renovate's cachix/git-hooks.nix manager is the only mechanism that
  # can. This entry is what surfaces a Renovate manager that has gone quiet.
  ["pre-commit-hooks"]="${SLOW_DAYS}"
)

function die_op() {
  printf 'flake-lock-staleness: %s\n' "$1" >&2
  exit 2
}

# The tool guard stands in front of every read below, because each of
# those reads reports a defect in the lock's contents and a pipeline that
# never ran read no contents. Without it an absent `jq` fails the first
# shape probe and is reported as a malformed `.root`, sending an operator
# into a file the check never parsed. The shared helper is what names the
# tool, so the sentence is the one every other check here prints.
require_tool jq

readonly lock_path="${FLAKE_LOCK_OVERRIDE:-flake.lock}"
payload_source_into lock_source FLAKE_LOCK_OVERRIDE 'flake.lock'
readonly lock_source
read_json_payload_into lock_json "${lock_path}" "${lock_source}"
readonly lock_json

printf '%s' "${lock_json}" | jq -e '(.root | type) == "string"' >/dev/null 2>&1 ||
  die_op "${lock_source}: .root missing or not a string"
printf '%s' "${lock_json}" | jq -e '.nodes | type == "object"' >/dev/null 2>&1 ||
  die_op "${lock_source}: invalid JSON or .nodes not an object"

# `now` is injectable because time is an input here: a fixture whose
# verdict depends on the day the suite runs is a fixture that starts
# failing on its own.
now="${STALENESS_NOW_EPOCH:-$(date +%s)}"
if [[ ! ${now} =~ ^[0-9]+$ ]]; then
  die_op "STALENESS_NOW_EPOCH is not a unix timestamp: ${now}"
fi
readonly now

# One record per top-level input: name, then the lastModified of the
# node it resolves to. A `follows` ref is an array rather than a node
# id; those resolve to a node this repo does not pin directly, so they
# are reported as unresolved and handled as an operational error rather
# than guessed at.
# Sorted by input name so the reported order is a property of this
# check rather than of the order a lock happens to list its inputs in.
# `nix` writes them sorted and a fixture need not, and an order that
# tracks the payload makes both the summary line and which stale input
# is named first unstable between them.
#
# The status is checked rather than left to `set -e`. The probes above
# establish that `.root` is a string and `.nodes` an object; they say
# nothing about the entry node itself, so a lock whose entry node is not
# an object clears both and dies here under jq's own exit code — a status
# the convention does not catalogue and no caller reads as a
# could-not-run. jq's raw diagnostic is dropped for the same reason the
# shape gate in `lib/payload.sh` drops its own: the sentence below names
# what could not be read, in this check's voice.
if ! records="$(printf '%s' "${lock_json}" | jq -r '
  .root as $root
  | (.nodes[$root].inputs // {})
  | to_entries
  | sort_by(.key)[]
  | .key as $name
  | if (.value | type) == "string"
    then $name + "\t" + (.value | tostring)
    else $name + "\t" + "-"
    end' 2>/dev/null)"; then
  die_op "${lock_source}: the entry node's input list could not be read"
fi

stale=0
checked=0
fresh_summary=()

while IFS=$'\t' read -r name node; do
  [[ -z ${name} ]] && continue
  if [[ -z ${THRESHOLD_DAYS[${name}]:-} ]]; then
    die_op "no staleness threshold declared for top-level input '${name}' (add one, or remove the input)"
  fi
  if [[ ${node} == "-" ]]; then
    die_op "top-level input '${name}' resolves through follows; this check reads directly-pinned inputs only"
  fi
  # Checked for the same reason as the input-list read above: a node that
  # is not an object cannot be indexed, and an unchecked substitution
  # ends the run under jq's status instead of this check's.
  if ! last_modified="$(printf '%s' "${lock_json}" |
    jq -r --arg n "${node}" '.nodes[$n].locked.lastModified // "-"' 2>/dev/null)"; then
    die_op "top-level input '${name}' (node '${node}') could not be read"
  fi
  if [[ ${last_modified} == "-" || ! ${last_modified} =~ ^[0-9]+$ ]]; then
    die_op "top-level input '${name}' (node '${node}') has no numeric locked.lastModified"
  fi
  limit_days="${THRESHOLD_DAYS[${name}]}"
  age_days=$(((now - last_modified) / SECONDS_PER_DAY))
  checked=$((checked + 1))
  if ((age_days > limit_days)); then
    printf 'STALE: %s last moved %d days ago, over its %d-day bound\n' \
      "${name}" "${age_days}" "${limit_days}" >&2
    stale=$((stale + 1))
  else
    fresh_summary+=("${name}=${age_days}d/${limit_days}d")
  fi
done <<<"${records}"

if ((checked == 0)); then
  die_op "${lock_source}: the entry node declares no top-level inputs"
fi

if ((stale > 0)); then
  printf 'flake.lock staleness check FAILED — %d of %d input(s) past their bound.\n' \
    "${stale}" "${checked}" >&2
  printf 'An input stops moving when the mechanism that refreshes it stops:\n' >&2
  printf 'check update-flake-lock.yml runs and the Renovate dependency dashboard.\n' >&2
  exit 1
fi

printf 'flake.lock staleness OK: %d input(s) within bounds (%s)\n' \
  "${checked}" "$(
    IFS=' '
    printf '%s' "${fresh_summary[*]}"
  )"
