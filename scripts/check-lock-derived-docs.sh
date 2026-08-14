#!/usr/bin/env bash
# scripts/check-lock-derived-docs.sh
#
# @description Lint: every workflow that writes a flake.lock runs a
# generator for each freshness hook that declares `flake.lock` a
# trigger, and commits the lock itself.

# A freshness hook whose `files` regex names `flake.lock` is a
# declaration that bumping the lock can leave its doc stale. A workflow
# that writes a lock therefore owns regenerating exactly that set: a doc
# it skips reaches the PR stale, the required freshness gate fails, and
# the change cannot merge without a human touching a branch the
# automation owns.
#
# Subjects are discovered rather than named — every workflow carrying a
# lock update in a run block — so a new lock-writing workflow is governed
# without editing this lint.
#
# Source-parsed rather than evaluated: `files` and `entry` are literal in
# the hook module, and each workflow's lists are literal YAML.
#
# Honors ROOT_OVERRIDE for fixtures (default: the repo root). Exits 0 on
# agreement, 1 on a set mismatch, 2 when an input could not be read.

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/log.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/log.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/awk-path.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/enumerate.sh"

root="${ROOT_OVERRIDE:-$(git rev-parse --show-toplevel)}"
readonly ROOT="${root}"
readonly HOOKS="${ROOT}/nix/hooks/freshness.nix"

require_tool yq
require_tool awk
require_tool grep

if [[ ! -f ${HOOKS} ]]; then
  printf 'lock-derived-docs: %s not found\n' "${HOOKS}" >&2
  exit 2
fi

# One record per hook block: <name>\037<files regex>\037<space-separated
# scripts/*.sh paths named anywhere in the block>. The delimiter is an
# ASCII unit separator rather than a tab: a block with an empty `files`
# value puts two delimiters back to back, and bash's `read` treats a tab
# as IFS whitespace, which collapses the pair and drops the empty field
# instead of preserving it.
#
# An awk fault is returned explicitly: the caller captures this in a
# command substitution inside an `if`, where errexit is suppressed, so a
# bare non-zero awk would leave the function returning 0 with a short
# block list.
function parse_hooks() {
  awk '
    /^  [A-Za-z0-9_-]+ = \{/ { name = $1; in_block = 1; files = ""; scripts = ""; next }
    in_block && /^  \};/ {
      printf "%s\037%s\037%s\n", name, files, scripts
      in_block = 0; next
    }
    in_block {
      if (match($0, /files = "[^"]*"/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/^files = "/, "", s); sub(/"$/, "", s)
        files = s
      }
      line = $0
      while (match(line, /scripts\/[A-Za-z0-9._-]+\.sh/)) {
        tok = substr(line, RSTART, RLENGTH)
        scripts = (scripts == "" ? tok : scripts " " tok)
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$(awk_path "${HOOKS}")" || return 1
}

if ! blocks="$(parse_hooks)"; then
  printf 'lock-derived-docs: hook block parse failed\n' >&2
  exit 2
fi

failed=0

# Generator keyed by the hook block that declares the lock a trigger.
declare -A hook_generators=()
total_blocks=0
lock_triggered=0
while IFS=$'\037' read -r name files scripts; do
  [[ -n ${name} ]] || continue
  total_blocks=$((total_blocks + 1))
  # Nix string literal: "\\." in source is the ERE "\.".
  ere="$(printf '%s' "${files}" | sed 's/\\\\/\\/g')"
  printf '%s\n' 'flake.lock' | grep --quiet --extended-regexp -- "${ere}" || continue
  lock_triggered=$((lock_triggered + 1))
  # Split on spaces explicitly: the global IFS is newline+tab, so a block
  # naming its generator more than once would otherwise stay one
  # unsplittable word and match no generator shape at all.
  IFS=' ' read -r -a script_list <<<"${scripts}"
  generator=''
  for s in "${script_list[@]}"; do
    [[ ${s} == scripts/refresh-*.sh ]] || continue
    generator="${s}"
    break
  done
  # The block's two declarations disagree: its trigger regex says a lock
  # bump can staleness this doc, but nothing in the block names a generator
  # the bumper could run. Dropping such a block would take it out of both
  # directions of the set comparison at once, so the hook the bumper
  # regenerates nothing for would read as agreement.
  if [[ -z ${generator} ]]; then
    printf 'lock-derived-docs: hook %s declares flake.lock a trigger but names no scripts/refresh-*.sh generator\n' \
      "${name}" >&2
    failed=$((failed + 1))
    continue
  fi
  hook_generators["${generator}"]="${name}"
done <<<"${blocks}"

# Guard-the-guard: this repo has lock-derived docs, so an empty match set
# means the block parser or the regex unescape broke rather than that
# nothing is lock-derived. An empty-at-exit-0 producer reads exactly like
# full agreement. Counted on blocks matched, not generators collected, so
# a matched block whose generator is missing stays the drift reported just
# above rather than masquerading as a broken parser.
if ((lock_triggered == 0)); then
  printf 'lock-derived-docs: no freshness hook declares flake.lock a trigger in %s — parser likely broke\n' \
    "${HOOKS}" >&2
  exit 2
fi

# Subject discovery. A workflow that writes a flake.lock owns
# regenerating what that lock derives, so the subject set is every
# workflow carrying a lock update in a run block — not a list of names a
# new workflow would have to be added to by hand.
declare -a workflow_files=()
glob_into workflow_files '.github/workflows YAML' \
  "${ROOT}/.github/workflows/*.yml" "${ROOT}/.github/workflows/*.yaml"

# Three facts from one parse. Reading the whole directory costs a fifth
# of a second, so no textual pre-filter stands between this lint and the
# syntax tree: a pre-filter would also be unsound against a folded run
# scalar whose source splits the phrase across lines and whose evaluated
# value joins it back together.
function workflow_facts() {
  yq '[
      ([.jobs[]?.steps[]?.run // ""] | map(select(test("nix flake update"))) | length > 0),
      ((.env.LOCK_DERIVED_GENERATORS // "") != ""),
      ((.env.COMMITTABLE_PATHS // "") != "")
    ] | map(tostring) | join(",")' -- "$1"
}

# One workflow-level env list, as a newline-separated body. Only read for
# a workflow whose fact line already reported the key non-empty, so an
# empty result here is a parse fault rather than an absent key.
function workflow_list() {
  yq --exit-status ".env.${2} // \"\"" -- "$1"
}

declare -a lock_writing=()
workflows_scanned=0
committable_total=0
for wf in "${workflow_files[@]}"; do
  workflows_scanned=$((workflows_scanned + 1))
  rel="${wf#"${ROOT}/"}"
  if ! facts="$(workflow_facts "${wf}")"; then
    printf 'lock-derived-docs: could not parse %s\n' "${rel}" >&2
    exit 2
  fi
  IFS=',' read -r writes_lock has_generators has_committable <<<"${facts}"

  if [[ ${writes_lock} != 'true' ]]; then
    # The reverse direction: lists that outlived the step they bounded.
    # Nothing downstream reads them, so left unreported they are config
    # that looks like a guarantee and is not one.
    if [[ ${has_generators} == 'true' || ${has_committable} == 'true' ]]; then
      printf 'lock-derived-docs: %s declares a lock-derived env list but runs no flake-lock update\n' \
        "${rel}" >&2
      failed=$((failed + 1))
    fi
    continue
  fi

  lock_writing+=("${rel}")

  if [[ ${has_generators} != 'true' ]]; then
    printf 'lock-derived-docs: %s writes flake.lock but declares no LOCK_DERIVED_GENERATORS\n' \
      "${rel}" >&2
    failed=$((failed + 1))
    continue
  fi

  if ! generators_raw="$(workflow_list "${wf}" LOCK_DERIVED_GENERATORS)"; then
    printf 'lock-derived-docs: could not parse %s\n' "${rel}" >&2
    exit 2
  fi

  # Cleared by name before the re-declaration, belt and braces: a map that
  # carried over would let the second subject inherit the first's
  # generator set and score a gap it never closed, and no diagnostic this
  # lint prints would say so.
  unset workflow_generators
  declare -A workflow_generators=()
  while IFS= read -r g; do
    [[ -n ${g} ]] || continue
    workflow_generators["${g}"]=1
    if [[ ! -x ${ROOT}/${g} ]]; then
      printf 'lock-derived-docs: %s is listed in LOCK_DERIVED_GENERATORS in %s but is not an executable generator\n' \
        "${g}" "${rel}" >&2
      failed=$((failed + 1))
    fi
  done <<<"${generators_raw}"

  for g in "${!hook_generators[@]}"; do
    if [[ -z ${workflow_generators["${g}"]:-} ]]; then
      printf 'lock-derived-docs: hook %s declares flake.lock a trigger, but %s is absent from LOCK_DERIVED_GENERATORS in %s\n' \
        "${hook_generators["${g}"]}" "${g}" "${rel}" >&2
      failed=$((failed + 1))
    fi
  done

  for g in "${!workflow_generators[@]}"; do
    if [[ -z ${hook_generators["${g}"]:-} ]]; then
      printf 'lock-derived-docs: %s is in LOCK_DERIVED_GENERATORS in %s, but no lock-triggered hook runs it\n' \
        "${g}" "${rel}" >&2
      failed=$((failed + 1))
    fi
  done

  if [[ ${has_committable} != 'true' ]]; then
    printf 'lock-derived-docs: COMMITTABLE_PATHS in %s is empty — it could commit nothing\n' \
      "${rel}" >&2
    failed=$((failed + 1))
    continue
  fi

  if ! committable_raw="$(workflow_list "${wf}" COMMITTABLE_PATHS)"; then
    printf 'lock-derived-docs: could not parse %s\n' "${rel}" >&2
    exit 2
  fi

  lock_listed='false'
  while IFS= read -r p; do
    [[ -n ${p} ]] || continue
    committable_total=$((committable_total + 1))
    [[ ${p} == 'flake.lock' ]] && lock_listed='true'
  done <<<"${committable_raw}"

  if [[ ${lock_listed} != 'true' ]]; then
    printf 'lock-derived-docs: COMMITTABLE_PATHS in %s omits flake.lock — it could not commit the lock it writes\n' \
      "${rel}" >&2
    failed=$((failed + 1))
  fi
done

# Guard-the-guard, sibling of the zero-lock-triggered-hooks check above.
# An empty subject set reads exactly like full agreement, so a discovery
# expression that stopped matching must fail loud rather than vouch for a
# set nothing was read from.
if ((${#lock_writing[@]} == 0)); then
  printf 'lock-derived-docs: no workflow runs a flake-lock update under %s — discovery likely broke\n' \
    "${ROOT}/.github/workflows" >&2
  exit 2
fi

if ((failed > 0)); then
  printf '%d lock-derived-doc gap(s)\n' "${failed}" >&2
  exit 1
fi

# A clean run is otherwise silent about how much it checked, which reads
# identically whether it compared real sets or two empty ones. State the
# breadth covered, on both halves of the comparison.
printf 'lock-derived-docs: ok — %d hook block(s) scanned, %d lock-triggered, %d workflow(s) scanned, %d lock-writing, %d committable path(s)\n' \
  "${total_blocks}" "${lock_triggered}" "${workflows_scanned}" \
  "${#lock_writing[@]}" "${committable_total}"
exit 0
