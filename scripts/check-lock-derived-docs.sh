#!/usr/bin/env bash
# scripts/check-lock-derived-docs.sh
#
# @description Lint: every workflow that writes a flake.lock runs a
# generator for each freshness hook that declares `flake.lock` a
# trigger, runs each generator it lists as workflow-derived from a
# freshness hook that declares `.github/workflows/ci.yml` a trigger,
# lists each pin-derived generator in no other list, and may commit
# exactly the lock plus the outputs all three generator lists declare
# with `@generates` / `@generates-block`, and uploads exactly that
# committable set from the job that writes the lock. A hook's
# trigger is its `files` and `excludes` patterns evaluated as pre-commit
# evaluates them, with Python `re.search`; a pattern that does not
# compile is a could-not-run. `ephemeral-refs-gap-fresh` is exempt from
# the generator list, because its generator's output does not depend on
# lock content.

# A freshness hook whose trigger admits `flake.lock` is a declaration
# that bumping the lock can leave its doc stale. A workflow
# that writes a lock therefore owns regenerating exactly that set: a doc
# it skips reaches the PR stale, the required freshness gate fails, and
# the change cannot merge without a human touching a branch the
# automation owns.
#
# A workflow may also list, in WORKFLOW_DERIVED_GENERATORS, generators
# whose docs derive from `.github/workflows/ci.yml` rather than from the
# lock. That list is optional and one-directional: many hooks name
# ci.yml, and only the generators a workflow chooses to run are bound to
# it. Each listed generator must be run by a hook whose trigger admits
# ci.yml, and its declared outputs join the committable bound, so
# COMMITTABLE_PATHS stays the one allowlist the credentialed job reads.
# A generator in both lists states two triggers for the same docs and is
# drift.
#
# A workflow may also list, in PIN_DERIVED_GENERATORS, generators whose
# output derives from an action pin by a registry lookup. No freshness
# hook can run one, since a hook has no network, so no hook binding
# applies; the lint that reads the output is the PR-time gate. Each must
# be an executable generator declaring its outputs, in neither other
# list, and its declared outputs join the committable bound like the
# other lists' outputs.
#
# Subjects are discovered rather than named — every workflow carrying a
# lock update in a run block — so a new lock-writing workflow is governed
# without editing this lint.
#
# Source-parsed rather than evaluated: `files`, `excludes` and
# `entry` are literal in the hook module, and each workflow's lists are
# literal YAML. The patterns are matched by `hook_filter_admits`
# (scripts/lib/hook-filter.sh) with Python `re.search`, the engine
# pre-commit runs them with, and never with POSIX ERE: the hook module
# uses lookaheads, which ERE lacks, and grep reads such a pattern as one
# that matches nothing, a verdict about a hook pre-commit does run on the
# lock. A path triggers a hook when `files` matches it and the `exclude`
# pattern pre-commit receives does not, which is pre-commit's own rule.
#
# A workflow's `jobs:` and `env:` are read as GitHub Actions reads a root
# key written as an alias (`ROOT_KEY_NODE` in scripts/lib/job-keys.sh);
# a workflow giving one twice, plain and as an alias, is one that could
# not be read.
#
# An env list written as an alias is read as its anchored text; a list
# that still holds an alias after sixteen resolving passes is refused
# with exit 2.
#
# Honors ROOT_OVERRIDE for fixtures (default: the repo root), and
# LOCK_TRIGGER_EXEMPT_OVERRIDE, a space-separated list of hook names that
# replaces the exempt set when set, even to empty, so a fixture module
# without the real exempt hook is not scored on its absence. Exits 0 on
# agreement, 1 on a set mismatch, 2 when an input could not be read.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "${_lib_dir}/lib/awk-path.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/generates.sh
source "${_lib_dir}/lib/generates.sh"
# shellcheck source=scripts/lib/repo.sh
source "${_lib_dir}/lib/repo.sh"
# shellcheck source=scripts/lib/job-keys.sh
source "${_lib_dir}/lib/job-keys.sh"
# shellcheck source=scripts/lib/hook-filter.sh
source "${_lib_dir}/lib/hook-filter.sh"

root="${ROOT_OVERRIDE:-$(repo_toplevel)}"
readonly ROOT="${root}"
readonly HOOKS="${ROOT}/nix/hooks/freshness.nix"

require_tool yq
require_tool awk
require_tool python3

if [[ ! -f ${HOOKS} ]]; then
  printf 'lock-derived-docs: %s not found\n' "${HOOKS}" >&2
  exit 2
fi

# One record per hook block: <name>\037<files regex>\037<exclude
# regex>\037<space-separated scripts/*.sh paths named anywhere in the
# block>. The delimiter is an ASCII unit separator rather than a tab: a
# block with an empty `files` value puts two delimiters back to back, and
# bash's `read` treats a tab as IFS whitespace, which collapses the pair
# and drops the empty field instead of preserving it. The two filter
# fields are read by `HOOK_FILTER_AWK` (scripts/lib/hook-filter.sh), and
# the exclude field is the joined pattern pre-commit receives.
#
# An awk fault is returned explicitly: the caller captures this in a
# command substitution inside an `if`, where errexit is suppressed, so a
# bare non-zero awk would leave the function returning 0 with a short
# block list.
function parse_hooks() {
  awk "${HOOK_FILTER_AWK}"'
    /^  [A-Za-z0-9_-]+ = \{/ {
      name = $1; in_block = 1; scripts = ""
      hook_filter_reset()
      next
    }
    in_block && /^  \};/ {
      printf "%s\037%s\037%s\037%s\n", name, hook_filter_files, hook_filter_exclude(), scripts
      in_block = 0; next
    }
    in_block {
      hook_filter_scan($0)
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

readonly CI_WORKFLOW='.github/workflows/ci.yml'

# Two trigger queries per hook block, in block order: does it admit
# flake.lock, and does it admit ci.yml.
function trigger_queries() {
  local name files exclude scripts
  while IFS=$'\037' read -r name files exclude scripts; do
    [[ -n ${name} ]] || continue
    printf '%s\037%s\037%s\037%s\0' \
      "${name}" "${files}" "${exclude}" 'flake.lock' \
      "${name}" "${files}" "${exclude}" "${CI_WORKFLOW}"
  done <<<"${blocks}"
}

# Captured with its status checked for the reason parse_hooks is: inside
# an `if`, errexit is suppressed, and a failed match run would otherwise
# arrive as an empty verdict list.
if ! verdicts="$(trigger_queries | hook_filter_admits lock-derived-docs)"; then
  printf 'lock-derived-docs: could not evaluate the hook trigger patterns in %s\n' "${HOOKS}" >&2
  exit 2
fi
declare -a trigger_verdicts=()
[[ -z ${verdicts} ]] || mapfile -t trigger_verdicts <<<"${verdicts}"

# Per block: <name>\037<admits flake.lock>\037<admits ci.yml>\037<scripts>,
# pairing each block with its two verdicts. A verdict count other than
# two per block means the queries and the answers fell out of step, and
# pairing them anyway would score one hook on another's filter.
matched=''
verdict_index=0
while IFS=$'\037' read -r name files exclude scripts; do
  [[ -n ${name} ]] || continue
  if ((verdict_index + 2 > ${#trigger_verdicts[@]})); then
    verdict_index=$((verdict_index + 2))
    continue
  fi
  matched+="${name}"$'\037'"${trigger_verdicts[verdict_index]}"$'\037'"${trigger_verdicts[verdict_index + 1]}"$'\037'"${scripts}"$'\n'
  verdict_index=$((verdict_index + 2))
done <<<"${blocks}"
if ((verdict_index != ${#trigger_verdicts[@]})); then
  printf 'lock-derived-docs: the trigger matcher returned %d verdict(s) for %d queries in %s\n' \
    "${#trigger_verdicts[@]}" "${verdict_index}" "${HOOKS}" >&2
  exit 2
fi

# Lock-triggered hooks that no lock-writing workflow need regenerate.
# The trigger of ephemeral-refs-gap-fresh admits every file type no
# ephemeral-refs extractor claims, flake.lock among them, so that a file
# of a new type reaches its check. Its generator renders the type labels
# of those files that carry a full-line `#` comment, and nothing else of
# their content: flake.lock is JSON that Nix writes, in which no line
# starts with `#`, so a bump that rewrites the lock cannot change the
# block. An exemption whose hook no longer admits the lock, or that names
# no hook block at all, is reported, so it cannot outlive its reason and
# excuse the next trigger or the next hook given that name instead.
declare -A LOCK_TRIGGER_EXEMPT=(
  ['ephemeral-refs-gap-fresh']=1
)
if [[ -n ${LOCK_TRIGGER_EXEMPT_OVERRIDE+set} ]]; then
  LOCK_TRIGGER_EXEMPT=()
  IFS=' ' read -r -a _exempt_names <<<"${LOCK_TRIGGER_EXEMPT_OVERRIDE}"
  for _exempt_name in ${_exempt_names+"${_exempt_names[@]}"}; do
    LOCK_TRIGGER_EXEMPT["${_exempt_name}"]=1
  done
fi
readonly -A LOCK_TRIGGER_EXEMPT
# Exempt names seen as hook blocks, so an exemption naming none is found.
declare -A exempt_seen=()

failed=0

# Generator keyed by the hook block that declares the lock a trigger.
declare -A hook_generators=()
# Generator keyed by the hook block that declares ci.yml a trigger.
declare -A ci_hook_generators=()
total_blocks=0
lock_triggered=0
lock_exempt=0
while IFS=$'\037' read -r name lock_match ci_match scripts; do
  [[ -n ${name} ]] || continue
  total_blocks=$((total_blocks + 1))
  [[ -n ${LOCK_TRIGGER_EXEMPT["${name}"]:-} ]] && exempt_seen["${name}"]=1
  if [[ -n ${LOCK_TRIGGER_EXEMPT["${name}"]:-} && ${lock_match} != 'true' ]]; then
    printf 'lock-derived-docs: hook %s is exempt from LOCK_DERIVED_GENERATORS but does not declare flake.lock a trigger\n' \
      "${name}" >&2
    failed=$((failed + 1))
  fi
  [[ ${lock_match} == 'true' || ${ci_match} == 'true' ]] || continue
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
  # A ci.yml-triggered hook naming no generator is no finding: most such
  # hooks are lints, and none is required of a workflow.
  if [[ ${ci_match} == 'true' && -n ${generator} ]]; then
    ci_hook_generators["${generator}"]="${name}"
  fi
  [[ ${lock_match} == 'true' ]] || continue
  lock_triggered=$((lock_triggered + 1))
  if [[ -n ${LOCK_TRIGGER_EXEMPT["${name}"]:-} ]]; then
    lock_exempt=$((lock_exempt + 1))
    continue
  fi
  # The block's two declarations disagree: its trigger regex says a lock
  # bump can leave this doc stale, but nothing in the block names a generator
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
done <<<"${matched}"

for name in "${!LOCK_TRIGGER_EXEMPT[@]}"; do
  [[ -n ${exempt_seen["${name}"]:-} ]] && continue
  printf 'lock-derived-docs: hook %s is exempt from LOCK_DERIVED_GENERATORS but no hook block in %s has that name\n' \
    "${name}" "${HOOKS#"${ROOT}/"}" >&2
  failed=$((failed + 1))
done

# Guard-the-guard: this repo has lock-derived docs, so an empty match set
# means the block parser or the pattern match broke rather than that
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

# The workflow-level `env:` node.
readonly ENV_NODE="${ROOT_KEY_NODE//@KEY@/env}"

# Five facts from one parse. Reading the whole directory costs a fifth
# of a second, so no textual pre-filter stands between this lint and the
# syntax tree: a pre-filter would also be unsound against a folded run
# scalar whose source splits the phrase across lines and whose evaluated
# value joins it back together. A job's merge list is read first mapping
# wins (YQ_MERGE_SPEC), the way the YAML merge specification reads it, so
# a step list a later mapping would override is not the one searched.
# `jobs:` and the workflow `env:` are read as `ROOT_KEY_NODE` reads a root
# key, so one written as an alias is read as GitHub Actions reads it, and
# one given twice, plain and as an alias, fails the parse. A step's run:
# written as an alias (`run: *body`) is exploded to its anchored text,
# which is what the runner executes. An env list written as an alias is
# read as its anchored text, so one aliased to an empty string or to null
# declares nothing.
function workflow_facts() {
  # shellcheck disable=SC2016 # yq program literal; its $ names are yq variables
  yq eval "${YQ_MERGE_SPEC[@]}" "(${ENV_NODE}) as \$env | (${JOBS_NODE}) as \$jobs"' | [
      ([$jobs | .[]?.steps[]? | (.run | explode(.)) // ""] | map(select(test("nix flake update"))) | length > 0),
      ((($env.LOCK_DERIVED_GENERATORS | explode(.)) // "") != ""),
      ((($env.COMMITTABLE_PATHS | explode(.)) // "") != ""),
      ((($env.WORKFLOW_DERIVED_GENERATORS | explode(.)) // "") != ""),
      ((($env.PIN_DERIVED_GENERATORS | explode(.)) // "") != "")
    ] | map(tostring) | join(",")' -- "$1"
}

# A workflow-level env list written as an alias is read as its anchored
# text. One `explode` pass resolves one level of an alias chain; a scalar
# list always resolves in one, since an anchor cannot sit on an alias,
# but a value that is itself a collection can nest an alias inside the
# text an alias stands for. So the value goes through sixteen passes, as
# `ON_NODE` in scripts/check-workflow-on-branches.sh resolves `on:`.
# shellcheck disable=SC2016 # yq program literal; its $ names are yq variables
readonly RESOLVE='(. as $n | [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16][] as $i ireduce ($n; explode(.)))'

# Stops the run on a workflow-level env list that still holds an alias
# after the sixteen passes, rather than score the alias marker as a path.
# Runs in the caller's shell, so its exit ends the run.
# Args: workflow file, env key, workflow path as reported
function refuse_unresolved_list() {
  local aliases
  if ! aliases="$(yq eval "${YQ_MERGE_SPEC[@]}" "[${ENV_NODE} | .${2} | ${RESOLVE} | ... | select(kind == \"alias\")] | length" -- "$1")"; then
    printf 'lock-derived-docs: could not parse %s\n' "$3" >&2
    exit 2
  fi
  if [[ ${aliases} != 0 ]]; then
    printf 'lock-derived-docs: %s: env.%s still holds a YAML alias after resolving; cannot read it\n' "$3" "$2" >&2
    exit 2
  fi
}

# One workflow-level env list, as a newline-separated body, read as its
# anchored text when written as an alias. Only read for a workflow whose
# fact line already reported the key non-empty, and after
# `refuse_unresolved_list` passed it, so an empty result here is a parse
# fault rather than an absent key.
function workflow_list() {
  yq eval "${YQ_MERGE_SPEC[@]}" --exit-status "${ENV_NODE} | (.${2} | ${RESOLVE}) // \"\"" -- "$1"
}

# The `actions/upload-artifact` steps of the jobs that run the lock
# update: their count on the first line, then the `path:` value of the
# first one. The jobs and the keys in them are resolved through
# `RESOLVE_JOB_ALIASES`, so a step list or a `with:` written as an alias
# is read as GitHub Actions reads it. The two values are joined into one
# string rather than emitted as two results: `yq` drops a variable bound
# by `as` from the second branch of a `,`, so that form prints the count
# alone.
function upload_candidates() {
  yq eval "${YQ_MERGE_SPEC[@]}" "[(${JOBS_NODE} // {}) | ${RESOLVE_JOB_ALIASES}"' | .[]?
      | select([.steps[]?.run // "" | select(test("nix flake update"))] | length > 0)
      | .steps[]? | select((.uses // "") | test("^actions/upload-artifact@"))]
    | [(length | tostring), (.[0].with.path // "" | tostring)] | join("\n")' -- "$1"
}

declare -a lock_writing=()
workflows_scanned=0
committable_total=0
declarations_total=0
generators_declaring=0
workflow_derived_total=0
pin_derived_total=0
upload_total=0
for wf in "${workflow_files[@]}"; do
  workflows_scanned=$((workflows_scanned + 1))
  rel="${wf#"${ROOT}/"}"
  if ! facts="$(workflow_facts "${wf}")"; then
    printf 'lock-derived-docs: could not parse %s\n' "${rel}" >&2
    exit 2
  fi
  IFS=',' read -r writes_lock has_generators has_committable \
    has_workflow_generators has_pin_generators <<<"${facts}"

  if [[ ${writes_lock} != 'true' ]]; then
    # The reverse direction: lists that outlived the step they bounded.
    # Nothing downstream reads them, so left unreported they are config
    # that looks like a guarantee and is not one.
    if [[ ${has_generators} == 'true' || ${has_committable} == 'true' ||
      ${has_workflow_generators} == 'true' || ${has_pin_generators} == 'true' ]]; then
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

  refuse_unresolved_list "${wf}" LOCK_DERIVED_GENERATORS "${rel}"
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
  # The generators this run may ask for output declarations. A listed path
  # with no executable behind it is already reported just below, and
  # handing it to the parser would turn that finding into a could-not-run
  # about a file the workflow itself is wrong to name.
  declare -a generator_sources=()
  # The list each source came from, so a diagnostic about a source names
  # the list the workflow author would edit. Reset for the same reason as
  # the maps around it.
  unset source_list
  declare -A source_list=()
  # The workflow-derived generators, so a pin-derived entry naming one is
  # found. Reset for the same reason as the maps around it.
  unset workflow_derived_names
  declare -A workflow_derived_names=()
  while IFS= read -r g; do
    [[ -n ${g} ]] || continue
    workflow_generators["${g}"]=1
    if [[ ! -x ${ROOT}/${g} ]]; then
      printf 'lock-derived-docs: %s is listed in LOCK_DERIVED_GENERATORS in %s but is not an executable generator\n' \
        "${g}" "${rel}" >&2
      failed=$((failed + 1))
      continue
    fi
    generator_sources+=("${ROOT}/${g}")
    source_list["${ROOT}/${g}"]='LOCK_DERIVED_GENERATORS'
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

  # The optional second list. Absent and empty read alike: a workflow
  # with no ci.yml-derived docs to refresh lists nothing.
  if [[ ${has_workflow_generators} == 'true' ]]; then
    refuse_unresolved_list "${wf}" WORKFLOW_DERIVED_GENERATORS "${rel}"
    if ! workflow_generators_raw="$(workflow_list "${wf}" WORKFLOW_DERIVED_GENERATORS)"; then
      printf 'lock-derived-docs: could not parse %s\n' "${rel}" >&2
      exit 2
    fi
    while IFS= read -r g; do
      [[ -n ${g} ]] || continue
      workflow_derived_names["${g}"]=1
      # Reported once and not scored further: whichever list is wrong, the
      # findings each list's own rules would add describe the same entry.
      if [[ -n ${workflow_generators["${g}"]:-} ]]; then
        printf 'lock-derived-docs: %s is in both LOCK_DERIVED_GENERATORS and WORKFLOW_DERIVED_GENERATORS in %s\n' \
          "${g}" "${rel}" >&2
        failed=$((failed + 1))
        continue
      fi
      workflow_derived_total=$((workflow_derived_total + 1))
      if [[ -z ${ci_hook_generators["${g}"]:-} ]]; then
        printf 'lock-derived-docs: %s is in WORKFLOW_DERIVED_GENERATORS in %s, but no freshness hook whose files names %s runs it\n' \
          "${g}" "${rel}" "${CI_WORKFLOW}" >&2
        failed=$((failed + 1))
      fi
      if [[ ! -x ${ROOT}/${g} ]]; then
        printf 'lock-derived-docs: %s is listed in WORKFLOW_DERIVED_GENERATORS in %s but is not an executable generator\n' \
          "${g}" "${rel}" >&2
        failed=$((failed + 1))
        continue
      fi
      generator_sources+=("${ROOT}/${g}")
      source_list["${ROOT}/${g}"]='WORKFLOW_DERIVED_GENERATORS'
    done <<<"${workflow_generators_raw}"
  fi

  # The optional third list, read the same way. A pin-derived generator
  # has no hook to be bound to, so the rules it is held to are the ones
  # every listed generator shares: it exists, it declares its outputs,
  # and those outputs are committable.
  if [[ ${has_pin_generators} == 'true' ]]; then
    refuse_unresolved_list "${wf}" PIN_DERIVED_GENERATORS "${rel}"
    if ! pin_generators_raw="$(workflow_list "${wf}" PIN_DERIVED_GENERATORS)"; then
      printf 'lock-derived-docs: could not parse %s\n' "${rel}" >&2
      exit 2
    fi
    while IFS= read -r g; do
      [[ -n ${g} ]] || continue
      other_list=''
      if [[ -n ${workflow_generators["${g}"]:-} ]]; then
        other_list='LOCK_DERIVED_GENERATORS'
      elif [[ -n ${workflow_derived_names["${g}"]:-} ]]; then
        other_list='WORKFLOW_DERIVED_GENERATORS'
      fi
      if [[ -n ${other_list} ]]; then
        printf 'lock-derived-docs: %s is in both %s and PIN_DERIVED_GENERATORS in %s\n' \
          "${g}" "${other_list}" "${rel}" >&2
        failed=$((failed + 1))
        continue
      fi
      pin_derived_total=$((pin_derived_total + 1))
      if [[ ! -x ${ROOT}/${g} ]]; then
        printf 'lock-derived-docs: %s is listed in PIN_DERIVED_GENERATORS in %s but is not an executable generator\n' \
          "${g}" "${rel}" >&2
        failed=$((failed + 1))
        continue
      fi
      generator_sources+=("${ROOT}/${g}")
      source_list["${ROOT}/${g}"]='PIN_DERIVED_GENERATORS'
    done <<<"${pin_generators_raw}"
  fi

  if [[ ${has_committable} != 'true' ]]; then
    printf 'lock-derived-docs: COMMITTABLE_PATHS in %s is empty — it could commit nothing\n' \
      "${rel}" >&2
    failed=$((failed + 1))
    continue
  fi

  refuse_unresolved_list "${wf}" COMMITTABLE_PATHS "${rel}"
  if ! committable_raw="$(workflow_list "${wf}" COMMITTABLE_PATHS)"; then
    printf 'lock-derived-docs: could not parse %s\n' "${rel}" >&2
    exit 2
  fi

  # Cleared by name before the re-declaration for the same reason the
  # generator map is: a set that carried over would let the second subject
  # be scored against the first subject's committable list, and no
  # diagnostic this lint prints would say which list it read.
  unset committable_set
  declare -A committable_set=()
  lock_listed='false'
  while IFS= read -r p; do
    [[ -n ${p} ]] || continue
    committable_total=$((committable_total + 1))
    committable_set["${p}"]=1
    [[ ${p} == 'flake.lock' ]] && lock_listed='true'
  done <<<"${committable_raw}"

  if [[ ${lock_listed} != 'true' ]]; then
    printf 'lock-derived-docs: COMMITTABLE_PATHS in %s omits flake.lock — it could not commit the lock it writes\n' \
      "${rel}" >&2
    failed=$((failed + 1))
  fi

  # The compute job hands the credentialed job its files through one
  # artifact, and that upload's `path:` list cannot read COMMITTABLE_PATHS
  # (octoscan reports an `env.*` expression in a `with:` value), so the
  # list is written out a second time. As a set it must equal the
  # committable one: a committable path the upload omits aborts the push
  # job, and an uploaded path nothing may commit is dead weight that reads
  # as permission. Lines are read as the upload action reads them —
  # trimmed, blank and `#` comment lines skipped. With no candidate step
  # or more than one, which list to compare is a guess, so that is the
  # finding rather than a silent pass.
  if ! upload_raw="$(upload_candidates "${wf}")"; then
    printf 'lock-derived-docs: could not parse %s\n' "${rel}" >&2
    exit 2
  fi
  upload_count="${upload_raw%%$'\n'*}"
  if [[ ${upload_count} == '0' ]]; then
    printf 'lock-derived-docs: %s has no actions/upload-artifact step in a job that runs the flake-lock update\n' \
      "${rel}" >&2
    failed=$((failed + 1))
  elif [[ ${upload_count} != '1' ]]; then
    printf 'lock-derived-docs: %s has %s actions/upload-artifact steps in jobs that run the flake-lock update; want exactly one\n' \
      "${rel}" "${upload_count}" >&2
    failed=$((failed + 1))
  else
    unset upload_set
    declare -A upload_set=()
    upload_lines=''
    [[ ${upload_raw} == *$'\n'* ]] && upload_lines="${upload_raw#*$'\n'}"
    while IFS= read -r p; do
      p="${p#"${p%%[![:space:]]*}"}"
      p="${p%"${p##*[![:space:]]}"}"
      [[ -n ${p} && ${p} != '#'* ]] || continue
      upload_set["${p}"]=1
    done <<<"${upload_lines}"
    for p in "${!committable_set[@]}"; do
      [[ -n ${upload_set["${p}"]:-} ]] && continue
      printf 'lock-derived-docs: %s is in COMMITTABLE_PATHS in %s but missing from its upload-artifact path list\n' \
        "${p}" "${rel}" >&2
      failed=$((failed + 1))
    done
    for p in "${!upload_set[@]}"; do
      upload_total=$((upload_total + 1))
      [[ -n ${committable_set["${p}"]:-} ]] && continue
      printf 'lock-derived-docs: %s is in the upload-artifact path list in %s but not in COMMITTABLE_PATHS\n' \
        "${p}" "${rel}" >&2
      failed=$((failed + 1))
    done
  fi

  # The committable set is exactly `flake.lock` plus what the generators
  # of all three lists declare they write, checked in both directions. A generator
  # regenerates a doc the credentialed job may not commit and the doc
  # reaches the PR as stale as if the generator had never run; a list
  # entry nothing declares widens what that job may commit past anything
  # the bump produces.
  #
  # There is deliberately no global "zero declarations, parser broke"
  # guard here. Such a guard would key on the same emptiness the
  # declares-nothing rule below reports, so a tree where every listed
  # generator declared nothing would exit 2 and leave that rule's exit 1
  # unreachable — the trap the zero-lock-triggered-hooks guard above
  # avoids by counting matched blocks rather than collected generators.
  # The declares-nothing rule fires per generator and owns that case. Lib
  # health is guarded on the other consumer of the same parser, whose
  # empty-scan guard covers the whole scripts/ tree, so a parser that
  # stopped matching fails loudly there.
  #
  # Captured with its status checked, because the substitution runs inside
  # an `if`, where errexit is suppressed: a generator that could not be
  # read would otherwise arrive as a shorter record stream, scored as a
  # generator that declares nothing.
  if ! declaration_records="$(generator_declarations "${generator_sources[@]}")"; then
    printf 'lock-derived-docs: could not read every generator listed in LOCK_DERIVED_GENERATORS, WORKFLOW_DERIVED_GENERATORS or PIN_DERIVED_GENERATORS in %s to collect its declared outputs\n' \
      "${rel}" >&2
    exit 2
  fi

  # Same reset discipline as the two maps above: declarations carried over
  # from the previous subject would let this one inherit outputs it never
  # runs a generator for, and score a gap it never closed.
  unset declared_paths
  declare -A declared_paths=()
  unset declaring_generators
  declare -A declaring_generators=()
  # A here-string of an empty variable still feeds one empty line, so a
  # workflow whose generators declared nothing reaches this loop as a
  # single blank record rather than as no iteration at all.
  while IFS=$'\037' read -r kind path script; do
    [[ -n ${kind} ]] || continue
    declarations_total=$((declarations_total + 1))
    declared_paths["${path}"]=1
    declaring_generators["${script}"]=1
    # Both kinds mean the generator writes that path, so both bind it to
    # the committable set; the split between whole file and spliced block
    # is a judgment about PR size, not about who writes the bytes.
    if [[ -z ${committable_set["${path}"]:-} ]]; then
      printf 'lock-derived-docs: %s declares %s, which is absent from COMMITTABLE_PATHS in %s\n' \
        "${script#"${ROOT}/"}" "${path}" "${rel}" >&2
      failed=$((failed + 1))
    fi
  done <<<"${declaration_records}"

  for src in "${generator_sources[@]}"; do
    generators_declaring=$((generators_declaring + 1))
    [[ -n ${declaring_generators["${src}"]:-} ]] && continue
    printf 'lock-derived-docs: %s is listed in %s in %s but declares no @generates or @generates-block path\n' \
      "${src#"${ROOT}/"}" "${source_list["${src}"]}" "${rel}" >&2
    failed=$((failed + 1))
  done

  for p in "${!committable_set[@]}"; do
    # The lock is the file the workflow writes itself rather than one a
    # generator declares, and the assertion just above already owns it.
    [[ ${p} == 'flake.lock' ]] && continue
    [[ -n ${declared_paths["${p}"]:-} ]] && continue
    printf 'lock-derived-docs: %s is in COMMITTABLE_PATHS in %s, but no listed generator declares it\n' \
      "${p}" "${rel}" >&2
    failed=$((failed + 1))
  done
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
printf 'lock-derived-docs: ok — %d hook block(s) scanned, %d lock-triggered (%d exempt), %d ci.yml-triggered generator(s), %d workflow(s) scanned, %d lock-writing, %d committable path(s), %d generator declaration(s) resolved across %d listed generator(s), %d workflow-derived, %d pin-derived, %d upload path(s)\n' \
  "${total_blocks}" "${lock_triggered}" "${lock_exempt}" "${#ci_hook_generators[@]}" \
  "${workflows_scanned}" "${#lock_writing[@]}" "${committable_total}" \
  "${declarations_total}" "${generators_declaring}" "${workflow_derived_total}" \
  "${pin_derived_total}" "${upload_total}"
exit 0
