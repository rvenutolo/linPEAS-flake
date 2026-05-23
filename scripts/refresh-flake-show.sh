#!/usr/bin/env bash
# Replace the content between <!-- BEGIN flake-show --> and <!-- END flake-show -->
# in docs/reference/flake-outputs.md with the current `nix flake show --all-systems`
# output.
#
# Usage:
#   scripts/refresh-flake-show.sh            # mutate docs/reference/flake-outputs.md in place
#   scripts/refresh-flake-show.sh --check    # exit 1 if the doc would change;
#                                            #   do NOT mutate the working tree

set -Eeuo pipefail
IFS=$'\n\t'
trap 'printf "[%s] %-5s line %s (exit %s): %s\n" \
  "$(date "+%Y-%m-%dT%H:%M:%S%z")" ERROR "${LINENO}" "$?" "${BASH_COMMAND}" >&2' ERR

function log() {
  printf '[%s] %-5s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" >&2
}
function log_info() { log INFO "$*"; }
function log_err() { log ERROR "$*"; }

# @description Verify a required CLI tool is on PATH; exit 1 if missing.
# @arg $1 tool name
function require_tool() {
  local -r tool="$1"
  if ! command -v "${tool}" >/dev/null 2>&1; then
    log_err "missing required tool: ${tool}"
    exit 1
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
  require_tool nix
  require_tool awk
  require_tool grep
  require_tool cmp
  require_tool sed

  local repo_root doc
  repo_root="$(git rev-parse --show-toplevel)"
  doc="${repo_root}/docs/reference/flake-outputs.md"
  readonly repo_root doc

  if [[ ! -f ${doc} ]]; then
    log_err "${doc} not found"
    exit 1
  fi
  if ! grep --quiet '<!-- BEGIN flake-show -->' "${doc}"; then
    log_err 'BEGIN marker missing from docs/reference/flake-outputs.md'
    exit 1
  fi
  if ! grep --quiet '<!-- END flake-show -->' "${doc}"; then
    log_err 'END marker missing from docs/reference/flake-outputs.md'
    exit 1
  fi

  local flake_show_file block_file doc_new
  flake_show_file="$(mktemp)"
  block_file="$(mktemp)"
  doc_new="$(mktemp)"
  # Use :- defaults so the trap (which fires after main() returns) does not
  # trip set -u when these locals have already gone out of scope.
  trap 'rm --force -- "${flake_show_file:-}" "${block_file:-}" "${doc_new:-}"' EXIT

  # --no-warn-dirty: suppress "Git tree is dirty" warning that would otherwise
  # leak into the README block and cause flaky --check diffs.
  # stderr discarded for the same reason.
  # nix flake show emits ANSI color escapes regardless of NO_COLOR / TTY
  # detection; sed strips them so the rendered README stays plain text.
  local raw_show
  raw_show="$(mktemp)"
  trap 'rm --force -- "${flake_show_file:-}" "${block_file:-}" "${doc_new:-}" "${raw_show:-}"' EXIT
  nix flake show --all-systems --no-warn-dirty >"${raw_show}" 2>/dev/null
  # Strip ANSI color escapes AND the leading flake-URL header line. The URL
  # contains a per-commit rev (in CI) and a per-checkout absolute path (locally),
  # neither of which are stable; without removing it, the readme-staleness
  # check would fail on every commit.
  sed --regexp-extended -e 's/\x1b\[[0-9;]*[mK]//g' -e '1{/^git\+/d}' \
    "${raw_show}" >"${flake_show_file}"

  # Blank lines between the HTML-comment markers and the fenced code block
  # match mdformat's canonical form. Without them, mdformat would rewrite
  # the surrounding doc on every commit and fight this script.
  {
    printf '<!-- BEGIN flake-show -->\n'
    printf '\n'
    printf '```text\n'
    cat -- "${flake_show_file}"
    printf '```\n'
    printf '\n'
    printf '<!-- END flake-show -->\n'
  } >"${block_file}"

  # Replace inclusive of markers (single occurrence). awk emits the block once
  # at the BEGIN marker, then suppresses every line until (and including) END.
  # Anchored to start-of-line so doc references to the marker (e.g. inside
  # a markdown bullet) do not falsely match and emit the block twice.
  awk -v rep="${block_file}" '
    /^<!-- BEGIN flake-show -->$/ {
      while ((getline line < rep) > 0) print line
      close(rep)
      skip = 1
      next
    }
    /^<!-- END flake-show -->$/ {
      skip = 0
      next
    }
    !skip { print }
  ' "${doc}" >"${doc_new}"

  if [[ ${check_only} == 'true' ]]; then
    # cmp short-circuits on first byte difference and supports --silent across
    # both GNU and BSD coreutils — diff --quiet is GNU-only.
    if ! cmp --silent -- "${doc}" "${doc_new}"; then
      log_err 'flake-show block in docs/reference/flake-outputs.md is stale. Run scripts/refresh-flake-show.sh and commit.'
      exit 1
    fi
    log_info 'flake-show block in docs/reference/flake-outputs.md is up to date'
    return 0
  fi

  mv -- "${doc_new}" "${doc}"
  log_info 'refreshed flake-show block in docs/reference/flake-outputs.md'
}

main "$@"
