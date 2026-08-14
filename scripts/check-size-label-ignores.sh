#!/usr/bin/env bash
# scripts/check-size-label-ignores.sh
#
# @description Lint: the size-label action's `IGNORED` list holds exactly
# the files this repo's generators declare they own — every `@generates`
# path is on the list, no `@generates-block` path is, and every other
# entry is one of this lint's declared exemptions.

# A size label is read as "how much of this PR is authored change", so a
# file a generator overwrites is excluded from the count and a
# hand-authored file is not. Both directions of that rule rot silently. A
# generator whose output nobody adds to the list inflates every PR that
# regenerates it, until the label stops being read at all; an entry for a
# file nothing writes scores a hand-edited doc's every line at zero, which
# is the same defect pointed the other way and the harder one to notice.
#
# Ownership is declared, not inferred. No generator here writes a whole
# file: each splices a `<!-- BEGIN x -->` block into a doc that also
# carries hand-authored prose, so "generator-owned" is a judgment about
# how much of the file the block is, and any coverage threshold would be
# a magic number that moves as the prose around the block grows. The
# judgment is therefore recorded at the generator, in the shdoc-style
# header block `scripts/_script_docs.awk` already reads:
#
#   @generates <path>        this script owns that file's content for
#                            size-label purposes; the path MUST be on
#                            IGNORED.
#   @generates-block <path>  this script splices a block into a file that
#                            is otherwise hand-authored; the path MUST
#                            NOT be on IGNORED, because the churn around
#                            the block is authored change.
#
# Only the header block counts, on the same terminator the annotation
# parser uses — the first line that is neither a comment nor blank — so a
# declaration written inside a function body governs nothing.
#
# Three rules:
#
#   1. Every `@generates` path appears in IGNORED.
#   2. No `@generates-block` path appears in IGNORED.
#   3. Every IGNORED entry is a declared path or an exemption.
#
# A `@generates-block` path counts as declared for rule 3, so rule 2 owns
# that finding alone. Reported by both, such an entry would be
# indistinguishable from an undeclared one, and neither rule could then
# be shown to catch anything the other misses.
#
# The subject step is discovered by the action it runs rather than by job
# or workflow name, so renaming the job leaves the list governed.
#
# Breadth is asserted rather than inferred: the run reports how many
# declarations it read, and reading none is a broken header parse
# reported as a could-not-run rather than a tree whose generators own
# nothing. `LINT_ALLOW_EMPTY_SCAN=1` suppresses that guard for a scan root
# that deliberately declares nothing.
#
# Honors SCRIPTS_DIR_OVERRIDE + LABELER_YML_OVERRIDE for fixtures, and
# LINT_ALLOW_EMPTY_SCAN for a scan root that declares nothing. Exits 0
# clean, 1 on any drift, 2 if yq is missing, if the workflow is absent or
# unparsable, if no step in it runs the size-label action, if that step
# declares no IGNORED list, or if no declaration was read at all.

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/log.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/log.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/enumerate.sh"

readonly SCRIPTS_DIR="${SCRIPTS_DIR_OVERRIDE:-scripts}"
readonly LABELER="${LABELER_YML_OVERRIDE:-.github/workflows/labeler.yml}"
readonly SIZE_ACTION='pascalgn/size-label-action'

# IGNORED entries no `@generates` annotation can ever claim, because
# nothing under scripts/ writes them. Each carries the reason it is not
# authored change; anything not on this list and not declared is drift.
readonly -a EXEMPT=(
  'CHANGELOG.md'      # git-cliff renders it from commit history
  'flake.lock'        # nix writes it
  'tests/fixtures/**' # fixture trees are authored as data, not as reviewable change
)

require_tool yq

if [[ ! -r ${LABELER} ]]; then
  printf '%s: %s not found or unreadable\n' "${0##*/}" "${LABELER}" >&2
  exit 2
fi

# --- Declarations -------------------------------------------------------

# path -> the script that declared it, for attribution in the diagnostic.
declare -A GENERATES=()
declare -A GENERATES_BLOCK=()
scripts_scanned=0
generates_count=0
generates_block_count=0

declare -a script_files=()
glob_into script_files "shell scripts under ${SCRIPTS_DIR}" "${SCRIPTS_DIR}/*.sh"

for script in "${script_files[@]}"; do
  [[ -f ${script} ]] || continue
  scripts_scanned=$((scripts_scanned + 1))
  # `|| [[ -n ... ]]` keeps a final line with no trailing newline, which
  # read reports as a failure even after populating the variable.
  while IFS= read -r line || [[ -n ${line} ]]; do
    # Header terminator: the first line that is neither a comment nor
    # blank, matching the annotation parser's own rule.
    [[ ${line} =~ ^[[:space:]]*$ ]] && continue
    [[ ${line} == '#'* ]] || break
    if [[ ${line} =~ ^#[[:space:]]+@generates-block[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
      GENERATES_BLOCK["${BASH_REMATCH[1]}"]="${script}"
      generates_block_count=$((generates_block_count + 1))
    elif [[ ${line} =~ ^#[[:space:]]+@generates[[:space:]]+([^[:space:]]+)[[:space:]]*$ ]]; then
      GENERATES["${BASH_REMATCH[1]}"]="${script}"
      generates_count=$((generates_count + 1))
    fi
  done <"${script}"
done

declarations=$((generates_count + generates_block_count))

# A header parse that stopped matching finds no declaration to require of
# the list, leaving rules 1 and 2 vacuous and rule 3 loud about entries it
# can no longer attribute — a verdict about content that was never read.
if ((declarations == 0)) && [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
  printf '%s: read 0 generator declaration(s) from %d script(s) under %s — with nothing declared, no ignore-list entry can be attributed and no generator can be found missing from the list; set LINT_ALLOW_EMPTY_SCAN=1 if this root deliberately declares nothing\n' \
    "${0##*/}" "${scripts_scanned}" "${SCRIPTS_DIR}" >&2
  exit 2
fi

# --- The ignore list ----------------------------------------------------

# Captured with its status checked rather than read through a process
# substitution, whose exit status is not propagated under `set -Eeuo
# pipefail`: a yq failure would otherwise yield an empty list and every
# rule would score clean against it.
if ! job_rows="$(yq eval '.jobs | keys | .[]' "${LABELER}")"; then
  printf '%s: could not evaluate %s with yq (malformed?)\n' "${0##*/}" "${LABELER}" >&2
  exit 2
fi

size_steps=0
ignored_raw=''
while IFS= read -r job; do
  [[ -n ${job} ]] || continue
  if ! uses="$(yq eval ".jobs.\"${job}\".steps[].uses // \"\"" "${LABELER}")"; then
    printf '%s: could not evaluate job %s in %s with yq\n' "${0##*/}" "${job}" "${LABELER}" >&2
    exit 2
  fi
  [[ ${uses} == *"${SIZE_ACTION}"* ]] || continue
  size_steps=$((size_steps + 1))
  if ! step_ignored="$(yq eval "
    .jobs.\"${job}\".steps[]
    | select(.uses // \"\" | test(\"${SIZE_ACTION}\"))
    | .env.IGNORED // \"\"
  " "${LABELER}")"; then
    printf '%s: could not evaluate the IGNORED list of job %s in %s with yq\n' \
      "${0##*/}" "${job}" "${LABELER}" >&2
    exit 2
  fi
  ignored_raw+="${step_ignored}"$'\n'
done <<<"${job_rows}"

# Discovery by property has the failure mode every discovery predicate
# has: match nothing, and the run reports the same clean line a tree with
# no drift does.
if ((size_steps == 0)); then
  printf '%s: found 0 step(s) running %s in %s — the ignore list this lint compares declarations against could not be located\n' \
    "${0##*/}" "${SIZE_ACTION}" "${LABELER}" >&2
  exit 2
fi

declare -A IGNORED=()
ignored_count=0
while IFS= read -r entry; do
  # A path in this list carries no whitespace, so stripping it collapses
  # both the indentation of a block scalar and a stray trailing space.
  entry="${entry//[[:space:]]/}"
  [[ -n ${entry} ]] || continue
  IGNORED["${entry}"]=1
  ignored_count=$((ignored_count + 1))
done <<<"${ignored_raw}"

if ((ignored_count == 0)); then
  printf '%s: the %s step in %s declares no IGNORED entries — every generator output would count toward PR size, and no declaration could be found missing from a list that is not there\n' \
    "${0##*/}" "${SIZE_ACTION}" "${LABELER}" >&2
  exit 2
fi

# --- Rules --------------------------------------------------------------

failed=0

function fail() {
  printf '%s\n' "$1" >&2
  failed=$((failed + 1))
}

# Rule 1: a declared-owned file the list never learned about.
for path in "${!GENERATES[@]}"; do
  if [[ -z ${IGNORED["${path}"]:-} ]]; then
    fail "${GENERATES["${path}"]} declares @generates ${path}, which is absent from the IGNORED list in ${LABELER}; regenerating it would count as authored change"
  fi
done

# Rule 2: a file whose hand-authored prose the list would silence along
# with the block spliced into it.
for path in "${!GENERATES_BLOCK[@]}"; do
  if [[ -n ${IGNORED["${path}"]:-} ]]; then
    fail "${GENERATES_BLOCK["${path}"]} declares @generates-block ${path}, which is on the IGNORED list in ${LABELER}; only part of that file is generated, so ignoring it drops the hand-authored churn around the block from the size count"
  fi
done

# Rule 3: an entry nothing claims. `@generates-block` paths are declared
# for this rule's purposes — rule 2 above is the one that reports them.
for entry in "${!IGNORED[@]}"; do
  [[ -n ${GENERATES["${entry}"]:-} ]] && continue
  [[ -n ${GENERATES_BLOCK["${entry}"]:-} ]] && continue
  exempt=0
  for allowed in "${EXEMPT[@]}"; do
    if [[ ${entry} == "${allowed}" ]]; then
      exempt=1
      break
    fi
  done
  ((exempt == 1)) && continue
  fail "${LABELER}: IGNORED lists ${entry}, which no script declares with @generates and which is not one of this lint's exemptions; every hand edit to it counts as zero toward the PR size label"
done

if ((failed > 0)); then
  printf '%d size-label ignore-list violation(s)\n' "${failed}" >&2
  exit 1
fi

printf '%s: ok — %d declaration(s) (%d @generates, %d @generates-block) across %d script(s) under %s, checked against %d IGNORED entry(ies) in %s\n' \
  "${0##*/}" "${declarations}" "${generates_count}" "${generates_block_count}" \
  "${scripts_scanned}" "${SCRIPTS_DIR}" "${ignored_count}" "${LABELER}"
exit 0
