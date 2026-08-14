#!/usr/bin/env bash
# scripts/check-lock-derived-docs.sh
#
# @description Lint: the flake-lock bump workflow runs a generator for
# every freshness hook that declares `flake.lock` a trigger, and commits
# the lock itself.

# A freshness hook whose `files` regex names `flake.lock` is a
# declaration that bumping the lock can leave its doc stale. The bump
# workflow writes a new lock, so it owns regenerating exactly that set:
# a doc it skips reaches the PR stale, the required freshness gate fails,
# and the bump cannot merge without a human touching a bot branch.
#
# Source-parsed rather than evaluated: `files` and `entry` are literal in
# the hook module, and the workflow's lists are literal YAML.
#
# Honors ROOT_OVERRIDE for fixtures (default: the repo root). Exits 0 on
# agreement, 1 on a set mismatch, 2 when an input could not be read.

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/log.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/log.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/awk-path.sh"

root="${ROOT_OVERRIDE:-$(git rev-parse --show-toplevel)}"
readonly ROOT="${root}"
readonly HOOKS="${ROOT}/nix/hooks/freshness.nix"
readonly WORKFLOW="${ROOT}/.github/workflows/update-flake-lock.yml"

require_tool yq
require_tool awk
require_tool grep

if [[ ! -f ${HOOKS} ]]; then
  printf 'lock-derived-docs: %s not found\n' "${HOOKS}" >&2
  exit 2
fi
if [[ ! -f ${WORKFLOW} ]]; then
  printf 'lock-derived-docs: %s not found\n' "${WORKFLOW}" >&2
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

# Generator keyed by the hook block that declares the lock a trigger.
declare -A hook_generators=()
total_blocks=0
while IFS=$'\037' read -r name files scripts; do
  [[ -n ${name} ]] || continue
  total_blocks=$((total_blocks + 1))
  # Nix string literal: "\\." in source is the ERE "\.".
  ere="$(printf '%s' "${files}" | sed 's/\\\\/\\/g')"
  printf '%s\n' 'flake.lock' | grep --quiet --extended-regexp -- "${ere}" || continue
  # Split on spaces explicitly: the global IFS is newline+tab, so a block
  # naming its generator more than once would otherwise stay one
  # unsplittable word and match no generator shape at all.
  IFS=' ' read -r -a script_list <<<"${scripts}"
  for s in "${script_list[@]}"; do
    [[ ${s} == scripts/refresh-*.sh ]] || continue
    hook_generators["${s}"]="${name}"
    break
  done
done <<<"${blocks}"

# Guard-the-guard: this repo has lock-derived docs, so an empty match set
# means the block parser or the regex unescape broke rather than that
# nothing is lock-derived. An empty-at-exit-0 producer reads exactly like
# full agreement.
if ((${#hook_generators[@]} == 0)); then
  printf 'lock-derived-docs: no freshness hook declares flake.lock a trigger in %s — parser likely broke\n' \
    "${HOOKS}" >&2
  exit 2
fi

# One workflow-level env list, as a newline-separated body. A `//` default
# keeps an absent key distinct from a file that does not parse: the former
# is an empty list this lint reports on, the latter is a could-not-run.
function workflow_list() {
  yq --exit-status ".env.${1} // \"\"" -- "${WORKFLOW}"
}

if ! generators_raw="$(workflow_list LOCK_DERIVED_GENERATORS)"; then
  printf 'lock-derived-docs: could not parse %s\n' "${WORKFLOW}" >&2
  exit 2
fi
if ! committable_raw="$(workflow_list COMMITTABLE_PATHS)"; then
  printf 'lock-derived-docs: could not parse %s\n' "${WORKFLOW}" >&2
  exit 2
fi

failed=0

declare -A workflow_generators=()
while IFS= read -r g; do
  [[ -n ${g} ]] || continue
  workflow_generators["${g}"]=1
  if [[ ! -x ${ROOT}/${g} ]]; then
    printf 'lock-derived-docs: %s is listed in LOCK_DERIVED_GENERATORS but is not an executable generator\n' \
      "${g}" >&2
    failed=$((failed + 1))
  fi
done <<<"${generators_raw}"

for g in "${!hook_generators[@]}"; do
  if [[ -z ${workflow_generators["${g}"]:-} ]]; then
    printf 'lock-derived-docs: hook %s declares flake.lock a trigger, but %s is absent from LOCK_DERIVED_GENERATORS\n' \
      "${hook_generators["${g}"]}" "${g}" >&2
    failed=$((failed + 1))
  fi
done

for g in "${!workflow_generators[@]}"; do
  if [[ -z ${hook_generators["${g}"]:-} ]]; then
    printf 'lock-derived-docs: %s is in LOCK_DERIVED_GENERATORS, but no lock-triggered hook runs it\n' \
      "${g}" >&2
    failed=$((failed + 1))
  fi
done

lock_listed='false'
committable_count=0
while IFS= read -r p; do
  [[ -n ${p} ]] || continue
  committable_count=$((committable_count + 1))
  [[ ${p} == 'flake.lock' ]] && lock_listed='true'
done <<<"${committable_raw}"

if ((committable_count == 0)); then
  printf 'lock-derived-docs: COMMITTABLE_PATHS is empty — the bump could commit nothing\n' >&2
  failed=$((failed + 1))
elif [[ ${lock_listed} != 'true' ]]; then
  printf 'lock-derived-docs: COMMITTABLE_PATHS omits flake.lock — the bump could not commit the lock it writes\n' >&2
  failed=$((failed + 1))
fi

if ((failed > 0)); then
  printf '%d lock-derived-doc gap(s)\n' "${failed}" >&2
  exit 1
fi

# A clean run is otherwise silent about how much it checked, which reads
# identically whether it compared a real pair of sets or two empty ones.
# State the breadth covered.
printf 'lock-derived-docs: ok — %d hook block(s) scanned, %d lock-triggered, %d committable path(s)\n' \
  "${total_blocks}" "${#hook_generators[@]}" "${committable_count}"
exit 0
