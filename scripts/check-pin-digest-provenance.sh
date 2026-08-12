#!/usr/bin/env bash
# scripts/check-pin-digest-provenance.sh
#
# @description Lint: a pin digest may not move under an unchanged
# version label. Diffs action pins (`uses: <path>@<sha> # <version>`)
# in workflows/composite actions and the octoscan container digest
# pair against the base ref; a changed SHA/digest whose version
# comment did not change is a repointed released tag (the
# digest-repoint supply-chain class) and fails. Floating-major pins
# (`# vN`) legitimately retarget across patch releases, so instead of
# a hard fail their new commit must be reachable from the upstream
# default branch — a force-pushed dangling commit fails.

# Gates the Renovate auto-merge path: a digest-only bump PR is by
# construction a repointed released tag. minimumReleaseAge does not
# delay it (the version's release timestamp is unchanged), and the
# daily ratchet-pin-audit calls a tag-matching pin "current", so this
# PR-time diff check is the only automated gate on that path.
#
# Reachability probe (floating-major only): the new SHA is
# dereferenced if it is an annotated-tag object, then compared against
# the upstream default branch; `identical`/`behind` passes,
# `ahead`/`diverged` fails. Any API failure exits 2 (loud) — never a
# silent pass. The probe runs only when a floating-major digest
# actually changed, so routine runs make no API calls.
#
# Exit: 0 pass, 1 violation, 2 operational error.
#
# Env overrides (test-only):
#   BASE_REF          — git ref for base content (default: origin/main)
#   BASE_DIR_OVERRIDE — read base files from this dir instead of git show
#   HEAD_DIR_OVERRIDE — read head files from this dir (default: .)

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/enumerate.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/enumerate.sh"

readonly BASE_REF="${BASE_REF:-origin/main}"
readonly BASE_DIR="${BASE_DIR_OVERRIDE:-}"
readonly HEAD_DIR="${HEAD_DIR_OVERRIDE:-.}"
readonly OCTOSCAN_FILE="scripts/octoscan-scan.sh"
readonly OCTOSCAN_IMAGE="ghcr.io/synacktiv/octoscan"
readonly GH_API_VERSION_HEADER="X-GitHub-Api-Version: 2022-11-28"
# Mirrors the self_repo skip in ratchet-pin-audit.yml: a `uses:` pin
# whose owner/repo is this repo has no upstream release tag to
# repoint against — Renovate's pinDigests rule tracks this repo's own
# main HEAD, not an upstream tag.
readonly SELF_REPO="${GITHUB_REPOSITORY:-rvenutolo/linPEAS-flake}"

function die_op() {
  printf 'pin-digest-provenance: %s\n' "$1" >&2
  exit 2
}

# True if PATH (relative to a scan root) is a pin-scanned file: a
# workflow YAML directly under .github/workflows/, or an
# action.yml/action.yaml at ANY depth under .github/actions/ — including
# zero path segments, i.e. a composite action living directly at
# .github/actions/action.yml. Single predicate shared by every discovery
# path below (directory-glob mode, used by both head and BASE_DIR
# override; git-ls-tree mode, used by real BASE_REF) so the base-side
# and head-side scans cannot diverge on file shape again: one definition
# of "what counts as a scanned file," not two independently-maintained
# ones.
# @arg $1 path relative to a scan root
function is_scanned_pin_file() {
  local -r path="$1"
  [[ ${path} =~ ^\.github/workflows/[^/]+\.ya?ml$ ]] && return 0
  [[ ${path} =~ ^\.github/actions/(.*/)?action\.ya?ml$ ]] && return 0
  return 1
}

# True if a `uses:` path's owner/repo segment is this repo itself — a
# self-reference pin (e.g. an absolute-slug invocation of one of this
# repo's own composite actions). Such a pin tracks this repo's own
# main HEAD, not an upstream release tag, so it has no comparable
# version label and no upstream to repoint against.
# @arg $1 uses path (owner/repo[/subpath])
function is_self_reference() {
  local -r path="$1"
  local -a parts
  IFS=/ read -ra parts <<<"${path}"
  ((${#parts[@]} >= 2)) || return 1
  [[ "${parts[0]}/${parts[1]}" == "${SELF_REPO}" ]]
}

# Emit the scanned file list (paths relative to ROOT) under a real
# directory root — shared by the head-side scan and the base-side scan
# when BASE_DIR_OVERRIDE points at a directory instead of a git ref.
# Lists every YAML file under .github/ and filters through
# is_scanned_pin_file, the same predicate the git-ls-tree scan below
# filters through, rather than re-deriving the shape via separate glob
# patterns per file class.
# @arg $1 root directory
function scanned_files_under() {
  local -r root="$1"
  local f rel
  shopt -s nullglob globstar
  for f in "${root}"/.github/**/*.yml "${root}"/.github/**/*.yaml; do
    rel="${f#"${root}"/}"
    is_scanned_pin_file "${rel}" && printf '%s\n' "${rel}"
  done
  shopt -u nullglob globstar
  if [[ -f "${root}/${OCTOSCAN_FILE}" ]]; then
    printf '%s\n' "${OCTOSCAN_FILE}"
  fi
}

# Emit the head-side scanned file list (paths relative to HEAD_DIR).
function head_files() {
  scanned_files_under "${HEAD_DIR}"
}

# Base-side scanned file list, resolved once via git ls-tree and cached
# here so base_files() and base_content() cannot diverge on what "is in
# base" — a file this set says is absent gets a benign empty read, a
# file it says is present gets a die_op if git show then fails.
declare -A BASE_FILE_SET=()
declare -i BASE_FILE_SET_LOADED=0

# Resolve the base-side scanned file list once via a single
# `git ls-tree`, filtered through is_scanned_pin_file (the same
# predicate scanned_files_under() applies to the head-side glob) plus
# the octoscan file. An ls-tree failure (an unfetched origin/main, a
# blob-filtered checkout whose lazy fetch is blocked, ...) dies loud
# instead of yielding an empty list — an empty base list would make
# every base pin read as "absent", which turns a real repoint into a
# one-sided key (add/remove), which passes.
function load_base_file_list() {
  ((BASE_FILE_SET_LOADED)) && return 0
  local path
  local -a tree_paths=()
  enumerate_into tree_paths "git ls-tree ${BASE_REF}" git ls-tree -r --name-only -z "${BASE_REF}"
  for path in "${tree_paths[@]}"; do
    if is_scanned_pin_file "${path}" || [[ ${path} == "${OCTOSCAN_FILE}" ]]; then
      BASE_FILE_SET["${path}"]=1
    fi
  done
  BASE_FILE_SET_LOADED=1
}

# Emit the base-side scanned file list (paths relative to repo root).
# Deliberately independent of head_files(): a file renamed between base
# and head must still be discovered under its own (old) base-side path,
# so the rename is seen as a SHA change on a shared (path, version) key
# rather than a same-path file swap that base_content() would silently
# read as "absent in base" and never compare.
function base_files() {
  if [[ -n ${BASE_DIR} ]]; then
    scanned_files_under "${BASE_DIR}"
    return 0
  fi
  load_base_file_list
  local path
  for path in "${!BASE_FILE_SET[@]}"; do
    printf '%s\n' "${path}"
  done
}

# Print base content of a file; empty output when absent in base. A
# file base_files() already proved present that then fails `git show`
# dies loud (die_op) rather than silently reading as absent — absent
# and read-failure are different operational facts and must never
# collapse to the same "pass" outcome.
# @arg $1 file path relative to repo root
function base_content() {
  local -r file="$1"
  if [[ -n ${BASE_DIR} ]]; then
    [[ -f "${BASE_DIR}/${file}" ]] || return 0
    cat -- "${BASE_DIR}/${file}"
    return 0
  fi
  load_base_file_list
  [[ -n ${BASE_FILE_SET[${file}]+set} ]] || return 0
  local content
  if ! content="$(git show "${BASE_REF}:${file}" 2>&1)"; then
    die_op "git show failed for ${BASE_REF}:${file}: ${content}"
  fi
  printf '%s' "${content}"
}

# Emit `file|path|version|sha` tuples for one file's content on stdin.
# @arg $1 file path label
function extract_pins() {
  local -r file="$1"
  local line
  if [[ ${file} == "${OCTOSCAN_FILE}" ]]; then
    local digest="" ver=""
    while IFS= read -r line; do
      if [[ ${line} =~ ^OCTOSCAN_DIGEST=\"(sha256:[a-f0-9]{64})\" ]]; then
        digest="${BASH_REMATCH[1]}"
      elif [[ ${line} =~ ^OCTOSCAN_VERSION=\"(v[0-9][A-Za-z0-9.]*)\" ]]; then
        ver="${BASH_REMATCH[1]}"
      fi
    done
    if [[ -n ${digest} && -n ${ver} ]]; then
      printf '%s|%s|%s|%s\n' "${file}" "${OCTOSCAN_IMAGE}" "${ver}" "${digest}"
    fi
    return 0
  fi
  local path sha version line_num=0 value
  while IFS= read -r line; do
    line_num=$((line_num + 1))
    if [[ ${line} =~ uses:[[:space:]]+([A-Za-z0-9._/-]+)@([0-9a-fA-F]{40})[[:space:]]*#[[:space:]]*([^[:space:]]+) ]]; then
      path="${BASH_REMATCH[1]}"
      sha="${BASH_REMATCH[2],,}"
      version="${BASH_REMATCH[3]}"
      # Local composite actions have no upstream to repoint.
      [[ ${path} == .* ]] && continue
      # Self-reference pins have no upstream tag either; skip before
      # the shape guard below ever sees this line (see is_self_reference).
      is_self_reference "${path}" && continue
      printf '%s|%s|%s|%s\n' "${file}" "${path}" "${version}" "${sha}"
      continue
    fi
    [[ ${line} =~ ^[[:space:]]*-?[[:space:]]*uses:[[:space:]] ]] || continue
    # Strict extraction above missed this `uses:` line. Isolate its value
    # (stripping one layer of surrounding quotes) to tell a local
    # composite-action ref (no upstream to repoint) from an unrecognized
    # pin shape — quoted, comment-less, or otherwise not matching the
    # strict pin regex above. A pin this gate cannot parse is a pin
    # silently outside its coverage, so that shape must die loud rather
    # than fall through as a same-value (no-op) comparison.
    if [[ ${line} =~ uses:[[:space:]]*[\"\']?([^[:space:]\"\']*) ]]; then
      value="${BASH_REMATCH[1]}"
    else
      value=""
    fi
    [[ -z ${value} || ${value} == .* ]] && continue
    [[ ${value} == *@* ]] || continue
    die_op "unrecognized uses: pin shape at ${file}:${line_num}: ${line}"
  done
  return 0
}

# Floating-major reachability probe.
# @arg $1 uses path   @arg $2 new sha
# Returns 0 reachable, 1 not reachable; dies (exit 2) on API error.
function check_reachable() {
  local -r path="$1" sha="$2"
  command -v gh >/dev/null 2>&1 ||
    die_op 'gh not found on PATH (needed for floating-major reachability probe)'
  local -a parts
  IFS=/ read -ra parts <<<"${path}"
  local -r owner_repo="${parts[0]}/${parts[1]}"
  local commit="${sha}" tag_out
  # Annotated-tag-object pins dereference to their commit; a 404 means
  # the SHA is not a tag object, i.e. already a commit.
  if tag_out="$(gh api --header "${GH_API_VERSION_HEADER}" \
    "repos/${owner_repo}/git/tags/${sha}" --jq '.object.sha' 2>&1)"; then
    [[ ${tag_out} =~ ^[0-9a-f]{40}$ ]] ||
      die_op "malformed tag deref payload for ${owner_repo}@${sha}: ${tag_out}"
    commit="${tag_out}"
  elif ! grep --quiet --ignore-case 'Not Found' <<<"${tag_out}"; then
    die_op "tag deref API error for ${owner_repo}@${sha}: ${tag_out}"
  fi
  local default_branch
  default_branch="$(gh api --header "${GH_API_VERSION_HEADER}" \
    "repos/${owner_repo}" --jq '.default_branch' 2>&1)" ||
    die_op "default-branch lookup failed for ${owner_repo}: ${default_branch}"
  [[ -n ${default_branch} && ${default_branch} != null ]] ||
    die_op "empty default branch for ${owner_repo}"
  # A pin that named an annotated-tag object resolved through one more
  # hop than a pin that named a commit directly. Both paths name
  # themselves, because a note that is silent about the direct path is a
  # prefix of the deref one and the two become indistinguishable.
  local deref_note=' via direct commit pin'
  if [[ ${commit} != "${sha}" ]]; then
    deref_note=" via tag object ${commit}"
  fi
  local status
  # A 404 here means the commit is unknown to the upstream repo at
  # all — the GC'd-dangling-commit signature this probe exists to
  # catch — so it is the violation itself (not reachable), not an
  # operational failure. Any other API error still dies loud. The note
  # names that mode: a commit upstream has never held and a commit it
  # holds off its default branch are different findings, and a caller
  # reading only the FAIL line cannot tell them apart.
  if ! status="$(gh api --header "${GH_API_VERSION_HEADER}" \
    "repos/${owner_repo}/compare/${default_branch}...${commit}" --jq '.status' 2>&1)"; then
    if grep --quiet --ignore-case 'Not Found' <<<"${status}"; then
      printf 'note: floating-major pin %s@%s unknown to %s: compare API reports no such commit%s\n' \
        "${path}" "${sha}" "${owner_repo}" "${deref_note}" >&2
      return 1
    fi
    die_op "compare API failed for ${owner_repo} ${default_branch}...${commit}: ${status}"
  fi
  case "${status}" in
  identical | behind)
    printf 'note: floating-major pin %s@%s verified reachable from %s (%s)%s\n' \
      "${path}" "${sha}" "${default_branch}" "${status}" "${deref_note}" >&2
    return 0
    ;;
  ahead | diverged)
    printf 'note: floating-major pin %s@%s is known to %s but sits off %s (%s)%s\n' \
      "${path}" "${sha}" "${owner_repo}" "${default_branch}" "${status}" "${deref_note}" >&2
    return 1
    ;;
  *)
    die_op "unexpected compare status '${status}' for ${owner_repo}"
    ;;
  esac
}

if [[ -z ${BASE_DIR} ]]; then
  git rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null ||
    die_op "cannot resolve ${BASE_REF} (is origin/main fetched?)"
  # Resolved here, synchronously, in the main shell, before any pin is
  # compared. base_content() reads BASE_FILE_SET for every file it is
  # asked about, so the set has to be populated by the time the base
  # loop below runs; resolving it up front also means a `git ls-tree`
  # failure surfaces once, as an operational error on its own, rather
  # than as a per-file symptom partway through a comparison.
  load_base_file_list
fi

# Producers are captured and status-checked rather than piped in through
# a process substitution, whose exit status the consuming loop cannot
# see: a producer that died would read as a producer that found nothing,
# and an empty scan is a clean verdict here.
#
# No failure fixture accompanies this call site: head_files() is a
# pure-bash glob over HEAD_DIR that runs no external command, and it
# returns 0 for every tree HEAD_DIR_OVERRIDE can point it at — a missing
# directory, an unreadable one, a plain file, or a directory standing
# where a workflow YAML belongs. The guard is here for whatever the
# producer comes to run, not for a reachable failure today.
head_tuples=""
head_file_count=0
if ! head_file_list="$(head_files)"; then
  die_op 'head_files failed'
fi
while IFS= read -r file; do
  [[ -n ${file} ]] || continue
  head_tuples+="$(extract_pins "${file}" <"${HEAD_DIR}/${file}")"$'\n'
  head_file_count=$((head_file_count + 1))
done <<<"${head_file_list}"

# No failure fixture accompanies this call site either. Under BASE_DIR
# base_files() is the same pure-bash glob as head_files(); without it,
# the only command that can fail is the `git ls-tree` inside
# load_base_file_list(), which the main-shell preload above — guarded on
# the identical BASE_DIR condition — has already run and cached, so
# base_files() invokes git zero times and a broken checkout has exited 2
# before this line is reached.
base_tuples=""
if ! base_file_list="$(base_files)"; then
  die_op 'base_files failed'
fi
while IFS= read -r file; do
  [[ -n ${file} ]] || continue
  # base_content() is captured on its own line, as a single-level
  # command substitution assigned directly in this loop body, which runs
  # in the main shell. Nesting it as `<<<"$(base_content ...)"` inside
  # the `$(extract_pins ...)` substitution below would run it in its own
  # throwaway subshell whose exit status nothing ever inspects — a
  # die_op there would print its message and vanish, and extract_pins
  # would just see empty stdin and return 0. Keeping it a standalone
  # assignment lets its exit status (and set -Eeuo pipefail) propagate.
  base_file_content="$(base_content "${file}")"
  base_tuples+="$(extract_pins "${file}" <<<"${base_file_content}")"$'\n'
done <<<"${base_file_list}"

# The octoscan pair is a load-bearing extraction target: if the file
# exists in head but the pair is not found, the var block was reshaped
# and this gate would silently stop covering it. Fail loud instead.
if [[ -f "${HEAD_DIR}/${OCTOSCAN_FILE}" ]] &&
  ! grep --quiet "^${OCTOSCAN_FILE}|" <<<"${head_tuples}"; then
  die_op "octoscan digest/version pair not found in ${OCTOSCAN_FILE} (extraction shape drift?)"
fi

# Grouping key is (path, version) — deliberately NOT including the
# source file. A pin's identity is what it points at, not which file
# names it; dropping the file lets a rename-plus-repoint (base pin in
# one file, head pin in another) still land on the same key instead of
# reading as an independent add + remove that skips the SHA compare.
keys="$(printf '%s\n%s\n' "${base_tuples}" "${head_tuples}" |
  awk -F'|' 'NF == 4 { print $2 "|" $3 }' | sort -u)"

violations=0
while IFS= read -r key; do
  [[ -n ${key} ]] || continue
  base_shas="$(awk -F'|' -v k="${key}" \
    '($2 "|" $3) == k { print $4 }' <<<"${base_tuples}" | sort -u)"
  head_shas="$(awk -F'|' -v k="${key}" \
    '($2 "|" $3) == k { print $4 }' <<<"${head_tuples}" | sort -u)"
  # Key only on one side = pin (or version) added/removed — not a
  # repoint. New versions ride minimumReleaseAge + the daily audit.
  [[ -n ${base_shas} && -n ${head_shas} ]] || continue
  [[ ${base_shas} == "${head_shas}" ]] && continue
  path="${key%%|*}"
  version="${key#*|}"
  if [[ ${version} =~ ^v[0-9]+$ ]]; then
    while IFS= read -r sha; do
      [[ -n ${sha} ]] || continue
      grep --quiet --line-regexp --fixed-strings "${sha}" <<<"${base_shas}" && continue
      if ! check_reachable "${path}" "${sha}"; then
        printf 'FAIL: floating-major digest %s@%s (%s) not reachable from upstream default branch\n' \
          "${path}" "${sha}" "${version}" >&2
        violations=1
      fi
    done <<<"${head_shas}"
  else
    # Naming the digests that moved makes the line answer "which SHA is
    # this now" without a second lookup, and keeps two repoints of the
    # same path and version — the same key reached by different routes —
    # from reporting identically.
    printf 'FAIL: digest repointed under unchanged version: %s (%s): %s -> %s\n' \
      "${path}" "${version}" \
      "$(paste --serial --delimiters=, <<<"${base_shas}")" \
      "$(paste --serial --delimiters=, <<<"${head_shas}")" >&2
    violations=1
  fi
done <<<"${keys}"

if ((violations != 0)); then
  printf 'pin digest provenance check FAILED — a digest moved under an unchanged version label.\n' >&2
  printf 'A repointed released tag is the digest-repoint supply-chain class. Review upstream before unblocking.\n' >&2
  exit 1
fi

# The pass banner reports the work done, not just the verdict. A clean
# run that scanned nothing and a clean run that scanned the whole tree
# are the same verdict but very different facts, and the counts are what
# separates them in a CI log.
head_pin_count="$(awk --field-separator='|' 'NF == 4' <<<"${head_tuples}" | wc --lines)"
printf 'pin digest provenance OK: %d pin(s) across %d file(s)\n' \
  "${head_pin_count}" "${head_file_count}"
