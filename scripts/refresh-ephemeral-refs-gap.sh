#!/usr/bin/env bash
# scripts/refresh-ephemeral-refs-gap.sh
#
# @description Regenerate the ephemeral-refs-gap managed block in
# docs/development/linting.md: the file types no ephemeral-refs extractor
# claims and that nonetheless carry `#` comments. The corpus inverts the
# lint's own type filter — same producer, same allowlist, all read from
# scripts/lib/ephemeral-refs-scope.sh — so the page cannot describe a
# narrower set of types than the ban leaves unread. Files the allowlist
# skips sit outside both sets and are accounted for by the page's
# allowlist bullet. A blocking-class shape found inside the corpus is
# refused
# rather than rendered: the prose around the block states the gap is
# empty, and rendering a non-zero count would publish a page that
# contradicts itself.
# @generates-block docs/development/linting.md
# @option --check exit 1 if the block would change; exit 2 if the check
# cannot run (doc missing, marker missing, no unclaimed sources, empty
# corpus, or a class regex that fails its canary) or if a blocking shape
# was found; do not mutate the working tree

# Env overrides (test-only):
#   EPHEMERAL_REFS_GAP_ROOT_OVERRIDE — alternate REPO_ROOT. Fixture roots
#     sit inside this repo, so the git producer still runs against them
#     and reports paths relative to the override — which is also what
#     keeps the fixtures clear of the `tests/fixtures/**` allowlist entry
#     that would otherwise skip every one of them.
#   EPHEMERAL_REFS_GAP_DOC_OVERRIDE — alternate output doc path
#   EPHEMERAL_REFS_GAP_UNION_OVERRIDE — alternate blocking union, which
#     the canary scenario points at a regex matching nothing

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "${_lib_dir}/lib/awk-path.sh"
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/ephemeral-refs-scope.sh
source "${_lib_dir}/lib/ephemeral-refs-scope.sh"
install_err_trap

REPO_ROOT="${EPHEMERAL_REFS_GAP_ROOT_OVERRIDE:-$(git rev-parse --show-toplevel)}"
readonly REPO_ROOT

# The block sits inside a bullet of `### Exemptions`, so every line it
# emits carries that bullet's four-space continuation indent. The markers
# are matched anchored to start-of-line including the indent, so the
# page's own prose about `BEGIN`/`END` marker pairs — which sits at
# column zero elsewhere on the page — cannot be mistaken for this block's
# opening and have the block spliced in twice.
readonly INDENT='    '
readonly MARKER_BEGIN='    <!-- BEGIN ephemeral-refs-gap -->'
readonly MARKER_END='    <!-- END ephemeral-refs-gap -->'

# A full-line comment: the first non-space character on the line is `#`.
# This is the same shape the YAML matcher reads, and it is what makes the
# corpus self-limiting — a format with no `#` comment convention
# contributes nothing without needing to be enumerated as an exception.
readonly RE_COMMENT='^[[:space:]]*#'

# @description NUL-delimited producer for the types the lint does not
# read: every path `git ls-files` reports that no extractor claims and
# the allowlist does not skip. The producer flags mirror the lint's
# exactly, so a file the lint reads cannot also appear here — the two
# sets are disjoint. They are not complements: a path that is a claimed
# type and also allowlisted sits outside both, and the page's allowlist
# bullet is what accounts for it.
# @stdout NUL-delimited source paths, sorted
# shellcheck disable=SC2329 # invoked indirectly, by name, via enumerate_into
function unclaimed_sources() {
  local src
  (cd "${REPO_ROOT}" && git ls-files --cached --others --exclude-standard -z) |
    while IFS= read -r -d '' src || [[ -n ${src} ]]; do
      [[ -n ${src} ]] || continue
      [[ $(language_of "${src}") == 'other' ]] || continue
      is_allowlisted "${src}" && continue
      printf '%s\0' "${src}"
    done |
    LC_ALL=C sort --zero-terminated
}

# @description Render the type label for one source: the extension with
# its dot, or the whole basename when the name has no extension. A
# leading dot is stripped before the test so dotfiles whose whole name is
# the convention — `.envrc`, `.gitignore` — render as themselves rather
# than as an extension named after the file.
# @arg $1 source path
# @stdout the label
function type_label_of() {
  local -r base="${1##*/}"
  local -r stem="${base#.}"
  if [[ ${stem} == *.* ]]; then
    printf '.%s\n' "${stem##*.}"
  else
    printf '%s\n' "${base}"
  fi
}

# @description Assert one class regex, and the blocking union, both match
# that class's canary. A union that has stopped matching a class renders
# "No blocking shape appears in any of them" over every corpus there is,
# and no file count, no verdict and no exit status would show it. So the
# matcher is proven live before anything is read. Deliberately answers to
# no override: an empty tree is a state an operator can vouch for, a
# degenerate matcher is not.
# @arg $1 class name  @arg $2 canary literal  @arg $3 class regex
# @arg $4 the blocking union in force
function assert_class() {
  local -r name="$1" canary="$2" class_re="$3" union="$4"
  if ! printf '%s\n' "${canary}" | grep --quiet --extended-regexp -- "${class_re}"; then
    log_err "class regex ${name} no longer matches its canary — the gap verdict would be vacuous"
    exit 2
  fi
  if ! printf '%s\n' "${canary}" | grep --quiet --extended-regexp -- "${union}"; then
    log_err "the blocking union no longer matches the ${name} canary — the gap verdict would be vacuous"
    exit 2
  fi
}

function main() {
  local check_only='false'
  if [[ ${1:-} == '--check' ]]; then
    check_only='true'
  elif [[ -n ${1:-} ]]; then
    log_err "unknown arg: ${1}"
    exit 2
  fi
  readonly check_only

  require_tool git
  require_tool grep
  require_tool awk
  require_tool sort
  require_tool cmp

  local doc
  doc="${EPHEMERAL_REFS_GAP_DOC_OVERRIDE:-${REPO_ROOT}/docs/development/linting.md}"
  readonly doc

  # The page is spliced, not written from scratch, so a missing page or a
  # missing marker is a could-not-run rather than drift: exit 1 would send
  # the operator to regenerate-and-commit a block that has nowhere to go.
  if [[ ! -f ${doc} ]]; then
    log_err "${doc} not found"
    exit 2
  fi
  if ! grep --quiet --fixed-strings --line-regexp -- "${MARKER_BEGIN}" "${doc}"; then
    log_err "BEGIN marker missing from ${doc}"
    exit 2
  fi
  if ! grep --quiet --fixed-strings --line-regexp -- "${MARKER_END}" "${doc}"; then
    log_err "END marker missing from ${doc}"
    exit 2
  fi

  local union
  union="${EPHEMERAL_REFS_GAP_UNION_OVERRIDE:-${UNION_BLOCKING}}"
  readonly union

  assert_class 'issue' "${CANARY_ISSUE}" "${RE_ISSUE}" "${union}"
  assert_class 'date' "${CANARY_DATE}" "${RE_DATE}" "${union}"
  assert_class 'planning' "${CANARY_PLANNING}" "${RE_PLANNING}" "${union}"
  assert_class 'review' "${CANARY_REVIEW}" "${RE_REVIEW}" "${union}"
  assert_class 'claude' "${CANARY_CLAUDE}" "${RE_CLAUDE}" "${union}"

  # One producer, no override path. A hand-fed source list would be a
  # second enumeration this generator's whole point is not to have, and
  # an override no scenario exercises is a shipped path nothing proves.
  local -a sources=()
  enumerate_into sources 'unclaimed sources' unclaimed_sources

  # A source list that survived the type filter and the allowlist but
  # holds no readable file is a scan that read nothing reading as a scan
  # that found nothing wrong. The corpus is what the block describes, so
  # its breadth is asserted where it is built.
  local -a corpus=()
  local src
  for src in ${sources+"${sources[@]}"}; do
    [[ -f "${REPO_ROOT}/${src}" ]] || continue
    if grep --binary-files=without-match --quiet --extended-regexp \
      -- "${RE_COMMENT}" "${REPO_ROOT}/${src}"; then
      corpus+=("${src}")
    fi
  done
  if ((${#corpus[@]} == 0)) && [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
    log_err "no unclaimed source carries a full-line comment — the gap this block describes cannot be read; set LINT_ALLOW_EMPTY_SCAN=1 if this tree deliberately holds none"
    exit 2
  fi

  # The verdict. Each candidate's comment lines are matched against the
  # blocking union; a hit is refused rather than counted, because the
  # prose wrapped around this block states the gap is empty and a
  # rendered non-zero count would publish a page that argues against
  # itself. The pipeline runs inside a command substitution guarded by
  # `if`, which both suppresses errexit on grep's no-match exit and keeps
  # the status this reads from being discarded by a process substitution.
  local violations=0
  local matched hit
  for src in ${corpus+"${corpus[@]}"}; do
    if matched="$(grep --binary-files=without-match --line-number --extended-regexp \
      -- "${RE_COMMENT}" "${REPO_ROOT}/${src}" |
      grep --extended-regexp -- "${union}")"; then
      while IFS= read -r hit; do
        [[ -n ${hit} ]] || continue
        log_err "${src}:${hit%%:*}: a blocking ephemeral-reference shape appears in a file type no extractor claims: ${hit#*:}"
        violations=$((violations + 1))
      done <<<"${matched}"
    fi
  done
  if ((violations > 0)); then
    log_err "${violations} blocking shape(s) in the gap between the ban's scope and the tree — fix the comment, or put the path on the shared skip allowlist in scripts/lib/ephemeral-refs-scope.sh"
    exit 2
  fi

  # LC_ALL=C so the rendered order is byte-deterministic. A dev locale
  # ignores the leading dot of `.toml` at the primary collation level and
  # files it among the `t` names, while a C-locale CI runner sorts every
  # dotted label ahead of `justfile` — one tree rendering two documents,
  # and --check red on whichever machine did not generate it.
  local labels_out
  local -a labels=()
  for src in "${corpus[@]}"; do
    labels+=("$(type_label_of "${src}")")
  done
  if ! labels_out="$(printf '%s\n' "${labels[@]}" | LC_ALL=C sort --unique)"; then
    log_err 'could not sort the type labels'
    exit 2
  fi
  local -a sorted_labels=()
  mapfile -t sorted_labels <<<"${labels_out}"

  local sentence='' label
  for label in "${sorted_labels[@]}"; do
    [[ -n ${label} ]] || continue
    sentence+="${sentence:+, }"'`'"${label}"'`'
  done

  local block_file doc_new
  block_file="$(make_temp)"
  doc_new="$(make_temp)"
  trap 'rm --force -- "${block_file:-}" "${doc_new:-}"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  # Blank lines inside the markers match mdformat's canonical form for a
  # block sitting in a list item. Without them mdformat would rewrite the
  # page on every commit and fight this script.
  {
    printf '%s\n' "${MARKER_BEGIN}"
    printf '\n'
    # shellcheck disable=SC2016 # literal backticks in markdown output
    printf '%sFile types no extractor claims and that carry `#` comments:\n' "${INDENT}"
    printf '%s%s.\n' "${INDENT}" "${sentence}"
    printf '%sNo blocking shape appears in any of them.\n' "${INDENT}"
    printf '\n'
    printf '%s\n' "${MARKER_END}"
  } >"${block_file}"

  # Replace inclusive of markers, once. awk emits the block at the BEGIN
  # marker then suppresses every line through END. Both patterns are
  # anchored to start-of-line and carry the indent, so the page's own
  # column-zero prose about marker pairs cannot match.
  awk -v rep="${block_file}" '
    /^    <!-- BEGIN ephemeral-refs-gap -->$/ {
      while ((getline line < rep) > 0) print line
      close(rep)
      skip = 1
      next
    }
    /^    <!-- END ephemeral-refs-gap -->$/ {
      skip = 0
      next
    }
    !skip { print }
  ' "$(awk_path "${doc}")" >"${doc_new}"

  local census
  printf -v census \
    'ephemeral-refs-gap: ok — %d unclaimed source(s), %d carrying comments, %d type label(s), 0 blocking shape(s)' \
    "${#sources[@]}" "${#corpus[@]}" "${#sorted_labels[@]}"

  if [[ ${check_only} == 'true' ]]; then
    if ! cmp --silent -- "${doc}" "${doc_new}"; then
      log_err "the ephemeral-refs-gap block in ${doc} is stale. Run scripts/refresh-ephemeral-refs-gap.sh and commit."
      exit 1
    fi
    printf '%s\n' "${census}"
    log_info "the ephemeral-refs-gap block in ${doc} is up to date"
    return 0
  fi

  mv -- "${doc_new}" "${doc}"
  printf '%s\n' "${census}"
  log_info "refreshed the ephemeral-refs-gap block in ${doc}"
}

main "$@"
