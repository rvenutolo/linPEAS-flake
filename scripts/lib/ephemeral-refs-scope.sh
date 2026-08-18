# scripts/lib/ephemeral-refs-scope.sh
#
# @description The ephemeral-reference ban's scan scope: which file types
# an extractor claims, which paths are skipped outright, and the class
# regexes a scan matches against. Shared by the lint that enforces the
# ban and by the generator that reports the gap between the ban's scope
# and the tree, so a class that widens widens for both and the reported
# gap stays the exact complement of the scan. Source after
# `set -Eeuo pipefail`.
# shellcheck shell=bash

# One record per claimed file type, `<extension>:<language>`. This is the
# single source of both the `git ls-files` pathspec the lint scans and
# the language its extractor is chosen by, so a type cannot be enumerated
# for one and unknown to the other. The generator reads the same records
# and takes their complement, which is what makes the gap it reports the
# exact set this lint does not read — a second hand-kept list would drift
# against this one and describe a narrower tree than the ban leaves
# unread.
readonly -a EPHEMERAL_REFS_TYPES=(
  'md:md'
  'sh:sh'
  'nix:nix'
  'yml:yaml'
  'yaml:yaml'
)

# @description Fill an array with the `git ls-files` pathspec selecting
# every claimed file type. Filled through a nameref rather than printed,
# because a pathspec is passed to git as separate arguments and a
# command substitution would split `*.md` on the caller's IFS and glob it
# against the working directory before git ever saw it.
# @arg $1 name of the array to fill
function ephemeral_refs_pathspec_into() {
  # Named distinctly so a caller passing a plainly-named array cannot
  # collide with the nameref, which bash rejects as a circular reference.
  local -n __pathspec_out_ref="$1"
  __pathspec_out_ref=()
  local __pathspec_record
  for __pathspec_record in "${EPHEMERAL_REFS_TYPES[@]}"; do
    __pathspec_out_ref+=("*.${__pathspec_record%%:*}")
  done
}

# @description Language of one source, by extension. Extension is the
# whole classifier: a shell library without a `.sh` suffix, and shell
# embedded in a workflow `run:` block, are out of scope by construction
# rather than by a content sniff that would have to guess.
# @arg $1 src_rel source path relative to REPO_ROOT
# @stdout one of `md`, `sh`, `nix`, `yaml`, `other`
function language_of() {
  local -r src_rel="$1"
  local record
  for record in "${EPHEMERAL_REFS_TYPES[@]}"; do
    if [[ ${src_rel} == *".${record%%:*}" ]]; then
      printf '%s\n' "${record#*:}"
      return 0
    fi
  done
  printf 'other\n'
}

# @description True when the given source path is on the skip-entirely
# file allowlist (`CHANGELOG.md`, `docs/releases.md`,
# `tests/fixtures/**`, `.claude/**`).
# @arg $1 src_rel source path relative to REPO_ROOT
function is_allowlisted() {
  local -r src_rel="$1"
  case "${src_rel}" in
  # `.claude/` holds Claude tooling rather than user-facing prose, so its
  # workflow-phase and label vocabulary is not an ephemeral reference.
  CHANGELOG.md | docs/releases.md | tests/fixtures/* | .claude/*)
    return 0
    ;;
  esac
  return 1
}

# Blocking classes. Boundary-guarded issue ref: a leading boundary that
# is not `-`, `&`, or a word char (so `#1-anchor` anchor targets,
# `&#123;` HTML numeric entities, and `#fff` hex colors do not match)
# followed by `#` and digits, then a trailing boundary that is not `-`
# or a word char (so `#1-anchor` is excluded by its trailing `-`).
readonly RE_ISSUE='(^|[^-&[:alnum:]_])#[0-9]+([^-[:alnum:]_]|$)'
readonly RE_DATE='([0-9]{4}-[0-9]{2}-[0-9]{2}|(January|February|March|April|May|June|July|August|September|October|November|December)[[:space:]]+[0-9]{4}|Q[1-4][[:space:]]+[0-9]{4})'
# Each enumerated shape carries the same left boundary guard as
# RE_ISSUE so it cannot match inside a larger token (e.g. `UTF-8` ->
# `F-8`, `PDF-1.7` -> `F-1`, `ID5:` -> `D5:`). No right guard on shapes
# ending in literal punctuation (`(D3)`, `D5:`, `(L4,`) — that suffix is
# itself the boundary.
readonly RE_PLANNING='(^|[^-&[:alnum:]_])(GAP-[0-9]+|P[0-9]+\.[0-9]+|Wave-P?[0-9]+|Phase[[:space:]]+[0-9]+|AU-P-[0-9]+|SC-POST-[0-9]+|plan[[:space:]]+[0-9]+|F-[0-9]+)'
readonly RE_REVIEW='(^|[^-&[:alnum:]_])(\(D[0-9]+\)|\(L[0-9]+[,)]|Per[[:space:]]+D[0-9]+|D[0-9]+:)'
readonly RE_CLAUDE='\.claude/'

# Advisory class: fuzzy causal-history phrases.
readonly RE_CAUSAL='(prior to|previously|Migration note|was reshaped|Tightened from|swapped|switched (from|to)|legacy .* was deleted|added in #?[0-9]+|post-PR #?[0-9]+)'

# The candidate pass matches one union per mode. Assembled from the
# constants above rather than written out again: a class whose regex
# widens must widen the union in the same edit, or the pass would set
# aside a file the scan would have flagged. None of the constants
# carries an unparenthesized top-level alternation, so joining them with
# `|` is the disjunction it reads as.
# shellcheck disable=SC2034 # read by scan_blocking/scan_advisory in scripts/check-ephemeral-refs.sh, which sources this library
readonly UNION_BLOCKING="${RE_ISSUE}|${RE_DATE}|${RE_PLANNING}|${RE_REVIEW}|${RE_CLAUDE}"
# shellcheck disable=SC2034 # read by scan_blocking/scan_advisory in scripts/check-ephemeral-refs.sh, which sources this library
readonly UNION_ADVISORY="${RE_CAUSAL}"

# One literal per class, each carrying a token that class must match.
# These are the canaries a run asserts against before it scans anything:
# they are what catches a union that has stopped matching a class it is
# supposed to cover, which no verdict and no file count would show — the
# run would simply set every file aside and exit clean.
# shellcheck disable=SC2034 # read by assert_class_canaries in scripts/check-ephemeral-refs.sh, which sources this library
readonly CANARY_ISSUE=' #123 '
# shellcheck disable=SC2034 # read by assert_class_canaries in scripts/check-ephemeral-refs.sh, which sources this library
readonly CANARY_DATE='2026-01-02'
# shellcheck disable=SC2034 # read by assert_class_canaries in scripts/check-ephemeral-refs.sh, which sources this library
readonly CANARY_PLANNING=' GAP-7'
# shellcheck disable=SC2034 # read by assert_class_canaries in scripts/check-ephemeral-refs.sh, which sources this library
readonly CANARY_REVIEW=' (D3)'
# shellcheck disable=SC2034 # read by assert_class_canaries in scripts/check-ephemeral-refs.sh, which sources this library
readonly CANARY_CLAUDE='.claude/'
# shellcheck disable=SC2034 # read by assert_class_canaries in scripts/check-ephemeral-refs.sh, which sources this library
readonly CANARY_CAUSAL='previously'
