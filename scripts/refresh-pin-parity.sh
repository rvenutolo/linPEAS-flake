#!/usr/bin/env bash
# scripts/refresh-pin-parity.sh
#
# @description Regenerate the pin-parity managed block in
# docs/architecture/auto-update.md: every tracked file carrying the
# canonical pin-shape literal, grouped by path into enforcement and
# documentation. The set is read from the tree on every run, so no
# hand-written list can name a file that has stopped carrying the shape
# or omit one that gained it. A file under tests/ is excluded; the block
# says so in prose, because a versioning-scheme migration touches the
# fixtures too and a silent omission would read as coverage.
# @generates-block docs/architecture/auto-update.md
# @option --check exit 1 if the block would change; exit 2 if the check
# cannot run (doc missing, marker missing, or no tracked file carries the
# literal at all); do not mutate the working tree
#
# Env overrides (test-only):
#   PIN_PARITY_ROOT_OVERRIDE — alternate REPO_ROOT. Fixture roots sit
#     inside this repo, so the git producer still runs against them and
#     reports paths relative to the override — which is also what keeps
#     the fixtures clear of the tests/ filter that would otherwise drop
#     every one of them.
#   PIN_PARITY_DOC_OVERRIDE — alternate output doc path

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
install_err_trap

REPO_ROOT="${PIN_PARITY_ROOT_OVERRIDE:-$(git rev-parse --show-toplevel)}"
readonly REPO_ROOT

readonly MARKER_BEGIN='<!-- BEGIN pin-parity -->'
readonly MARKER_END='<!-- END pin-parity -->'

# The canonical pin shape, matched as a fixed string rather than as a
# regex. The subject of the search is the regex source text itself, so
# matching it literally is what makes the search exact: the leading
# `[0-9]{8}-` is the whole discriminator between this fact and the
# action-SHA `[0-9a-f]{7,40}` fact, which shares the tail and is enforced
# by different scripts against different inputs.
readonly LITERAL='[0-9]{8}-[0-9a-f]{7,40}'

# @description NUL-delimited producer for every tracked file carrying the
# literal, excluding tests/. Paths are reported relative to REPO_ROOT, so
# a fixture root scanned through the override is filtered by its own
# tests/ subtree rather than by the real one.
# @stdout NUL-delimited paths, sorted
# shellcheck disable=SC2329 # invoked indirectly, by name, via enumerate_into
function carrying_sources() {
  local src
  (cd "${REPO_ROOT}" && git ls-files --cached --others --exclude-standard -z) |
    while IFS= read -r -d '' src || [[ -n ${src} ]]; do
      [[ -n ${src} ]] || continue
      if [[ ${src} == tests/* ]]; then continue; fi
      [[ -f "${REPO_ROOT}/${src}" ]] || continue
      if grep --binary-files=without-match --quiet --fixed-strings \
        -- "${LITERAL}" "${REPO_ROOT}/${src}"; then
        printf '%s\0' "${src}"
      fi
    done |
    LC_ALL=C sort --zero-terminated
}

# @description Emit one group: a labelled lead-in line, then either a
# bullet per path or a sentence saying the group is empty. An empty group
# gets a sentence rather than a bare label followed by nothing, because a
# label with no list under it reads as truncated output rather than as a
# group that genuinely holds nothing. The label is plain text closing on
# a colon rather than emphasis: bold standing alone on a line is a
# heading wearing the wrong markup, which the markdown linter rejects,
# and a real heading would put a generated block's internals in the
# page's table of contents.
# @arg $1 group label  @arg $2 empty-case sentence  @arg $@ the paths
function emit_group() {
  local -r label="$1" empty_sentence="$2"
  shift 2
  printf '%s:\n\n' "${label}"
  if (($# == 0)); then
    printf '%s\n\n' "${empty_sentence}"
    return 0
  fi
  local path
  for path in "$@"; do
    # shellcheck disable=SC2016 # literal backticks in markdown output
    printf -- '- `%s`\n' "${path}"
  done
  printf '\n'
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
  doc="${PIN_PARITY_DOC_OVERRIDE:-${REPO_ROOT}/docs/architecture/auto-update.md}"
  readonly doc

  # The page is spliced, not written from scratch, so a missing page or a
  # missing marker is a could-not-run rather than drift: exit 1 would send
  # the operator to regenerate a block that has nowhere to go.
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

  # One producer, no hand-fed path list. A second enumeration is the
  # thing this generator exists not to have. `enumerate_into` asserts
  # both the producer's status and the breadth of what it found, so a
  # literal that has stopped matching anything — which is exactly the
  # state a completed scheme migration leaves behind — is refused rather
  # than rendered as a page saying no file carries the shape.
  local -a sources=()
  enumerate_into sources 'files carrying the canonical pin shape' carrying_sources

  local -a enforcement=() documentation=()
  local src
  for src in ${sources+"${sources[@]}"}; do
    if [[ ${src} == docs/* ]]; then
      documentation+=("${src}")
    else
      enforcement+=("${src}")
    fi
  done

  local block_file doc_new
  block_file="$(make_temp)"
  doc_new="$(make_temp)"
  trap 'rm --force -- "${block_file:-}" "${doc_new:-}"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  # Blank lines inside the markers match mdformat's canonical form for a
  # block of top-level prose. Without them mdformat rewrites the page on
  # every commit and fights this script.
  {
    printf '%s\n\n' "${MARKER_BEGIN}"
    emit_group 'Enforcement and configuration' \
      'No tracked enforcement or configuration file carries the shape.' \
      ${enforcement+"${enforcement[@]}"}
    emit_group 'Documentation' \
      'No tracked documentation carries the shape.' \
      ${documentation+"${documentation[@]}"}
    # shellcheck disable=SC2016 # literal backticks in markdown output
    printf 'Test fixtures and harnesses under `tests/` carry the shape too and are\n'
    printf 'excluded from these lists; a scheme migration updates them alongside the\n'
    printf 'check each one drives.\n\n'
    printf '%s\n' "${MARKER_END}"
  } >"${block_file}"

  # Replace inclusive of markers, once. awk emits the block at the BEGIN
  # marker then suppresses every line through END. Both patterns are
  # anchored whole-line, so prose elsewhere on the page that names a
  # marker pair cannot be mistaken for this block's opening.
  awk -v rep="${block_file}" '
    /^<!-- BEGIN pin-parity -->$/ {
      while ((getline line < rep) > 0) print line
      close(rep)
      skip = 1
      next
    }
    /^<!-- END pin-parity -->$/ {
      skip = 0
      next
    }
    !skip { print }
  ' "$(awk_path "${doc}")" >"${doc_new}"

  local census
  printf -v census \
    'pin-parity: ok — %d file(s) carrying the pin shape: %d enforcement, %d documentation' \
    "${#sources[@]}" "${#enforcement[@]}" "${#documentation[@]}"

  if [[ ${check_only} == 'true' ]]; then
    if ! cmp --silent -- "${doc}" "${doc_new}"; then
      log_err "the pin-parity block in ${doc} is stale. Run scripts/refresh-pin-parity.sh and commit."
      exit 1
    fi
    printf '%s\n' "${census}"
    log_info "the pin-parity block in ${doc} is up to date"
    return 0
  fi

  mv -- "${doc_new}" "${doc}"
  printf '%s\n' "${census}"
  log_info "refreshed the pin-parity block in ${doc}"
}

main "$@"
