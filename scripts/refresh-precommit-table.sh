#!/usr/bin/env bash
# scripts/refresh-precommit-table.sh
#
# @description Regenerate the precommit-table managed block in
# docs/development/git.md from the current pre-commit hook manifest
# in the flake.
# @generates-block docs/development/git.md
# @option --check exit 1 if the doc would change; exit 2 if the doc is
# missing; do not mutate the working tree

# Replace the content between <!-- BEGIN precommit-table --> and <!-- END precommit-table -->
# in docs/development/git.md with the current pre-commit hook manifest from the flake.
#
# Usage:
#   scripts/refresh-precommit-table.sh            # mutate docs/development/git.md in place
#   scripts/refresh-precommit-table.sh --check    # exit 1 if the doc would change;
#                                                 #   exit 2 if the doc is missing;
#                                                 #   do NOT mutate the working tree

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/log.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/log.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/awk-path.sh"
# shellcheck source=scripts/lib/temp.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/temp.sh"
install_err_trap

# Temp files removed by the EXIT trap. Declared at script scope, not main-local:
# the EXIT trap fires after main() returns and its locals leave scope, so a
# main-local would read as empty at trap time and the in-repo .md temp would
# leak on an abnormal exit.
repo_root=''
hooks_file=''
block_file=''
doc_new=''
doc_fmt=''

# @description Remove every temp file this script creates, then sweep any
# stray in-repo .md temps left by an interrupted earlier run.
function cleanup() {
  rm --force -- "${hooks_file}" "${block_file}" "${doc_new}" "${doc_fmt}"
  if [[ -n ${repo_root} ]]; then
    local stray
    shopt -s nullglob
    # glob-exempt: a leftover in-repo temp file is normally absent, so an empty match is this loop's expected state
    for stray in "${repo_root}"/.refresh-precommit-*.md; do
      rm --force -- "${stray}"
    done
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
  require_tool jq
  require_tool awk
  require_tool cmp
  # treefmt runs mdformat (with mdformat-gfm) over the generated doc so the
  # script's output matches what treefmt would emit after a commit. Without
  # this, mdformat-gfm's table-cell escapes (e.g. `docs/_data` → `docs/\_data`,
  # `scripts/*.sh` → `scripts/\*.sh`) cause the regenerated table to differ
  # from the committed file, leaving precommit-table-fresh red on every commit.
  require_tool treefmt

  local doc
  repo_root="$(git rev-parse --show-toplevel)"
  doc="${repo_root}/docs/development/git.md"
  readonly repo_root doc

  # The doc is spliced, not written from scratch, so its absence is a
  # could-not-run condition rather than drift: exit 2 so the caller sends
  # the operator to the missing file instead of to a regenerate-and-commit.
  if [[ ! -f ${doc} ]]; then
    log_err "${doc} not found"
    exit 2
  fi
  if ! grep --quiet '^<!-- BEGIN precommit-table -->$' "${doc}"; then
    log_err 'BEGIN marker missing from docs/development/git.md'
    exit 1
  fi
  if ! grep --quiet '^<!-- END precommit-table -->$' "${doc}"; then
    log_err 'END marker missing from docs/development/git.md'
    exit 1
  fi

  # Set cleanup traps before the first `make_temp` so any temp created below
  # is
  # removed on exit or signal. The signal handlers force exit, which
  # re-triggers the EXIT trap so cleanup runs exactly once. A bare
  # `trap cleanup INT` would run the handler then RESUME, so Ctrl-C would not
  # abort — the explicit `exit` is required.
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  hooks_file="$(make_temp)"
  block_file="$(make_temp)"
  doc_new="$(make_temp)"
  # treefmt walks up to find flake.nix as projectRootFile, so the formatted
  # tmp file must live inside the repo. Hidden name + .md extension so
  # treefmt's mdformat picks it up; .gitignore keeps it untracked if a crash
  # bypasses the EXIT trap.
  doc_fmt="$(make_temp "${repo_root}/.refresh-precommit-XXXXXX.md")"

  local sys
  sys="$(nix eval --impure --raw --expr 'builtins.currentSystem')"

  nix eval --json ".#devTooling.${sys}.preCommitHooks" >"${hooks_file}"

  # Render the block in prettier's canonical padded-column form.
  # Compute the max widths for col1 (`name`) and col2 (description), then pad
  # every cell so the regenerated table is stable after `nix fmt` runs prettier.
  local col1_width col2_width

  # col1: max of header "Hook" (4) and max(len("`name`")) across all hooks
  col1_width="$(
    jq --raw-output '
      (["Hook"] + (keys | map("`" + . + "`"))) | map(length) | max
    ' "${hooks_file}"
  )"
  # col2: max of header "What it checks" (14) and max(len(description)) across all hooks
  col2_width="$(
    jq --raw-output '
      (["What it checks"] + [.[]] ) | map(length) | max
    ' "${hooks_file}"
  )"

  # Render the block: markers, blank line, padded header, separator, rows, blank line, end marker.
  {
    printf '<!-- BEGIN precommit-table -->\n'
    printf '\n'
    # Header row: pad "Hook" to col1_width, "What it checks" to col2_width
    printf '| %-*s | %-*s |\n' \
      "${col1_width}" 'Hook' \
      "${col2_width}" 'What it checks'
    # Separator row: dashes matching each column width
    printf '| %s | %s |\n' \
      "$(printf '%*s' "${col1_width}" '' | tr ' ' '-')" \
      "$(printf '%*s' "${col2_width}" '' | tr ' ' '-')"
    # Data rows — use jq to read the sorted JSON and print padded lines
    jq --raw-output --argjson w1 "${col1_width}" --argjson w2 "${col2_width}" '
      to_entries | sort_by(.key)[] |
      "| " + ("`" + .key + "`" | . + (" " * ($w1 - length))) +
      " | " + (.value | . + (" " * ($w2 - length))) + " |"
    ' "${hooks_file}"
    printf '\n'
    printf '<!-- END precommit-table -->\n'
  } >"${block_file}"

  # Replace inclusive of markers. awk emits the block once at BEGIN marker,
  # then suppresses every line until (and including) END.
  # Anchored to start-of-line so doc references to the marker don't falsely match.
  awk -v rep="${block_file}" '
    /^<!-- BEGIN precommit-table -->$/ {
      while ((getline line < rep) > 0) print line
      close(rep)
      skip = 1
      next
    }
    /^<!-- END precommit-table -->$/ {
      skip = 0
      next
    }
    !skip { print }
  ' "$(awk_path "${doc}")" >"${doc_new}"

  # Run treefmt over the regenerated doc so the comparison target matches
  # what the formatter chain (mdformat-gfm) would produce on commit. Without
  # this step, mdformat's table-cell escapes cause persistent drift between
  # the script output and the committed file.
  cp -- "${doc_new}" "${doc_fmt}"
  treefmt --no-cache --quiet -- "${doc_fmt}" >/dev/null

  if [[ ${check_only} == 'true' ]]; then
    # cmp short-circuits on first byte difference and supports --silent across
    # both GNU and BSD coreutils — diff --quiet is GNU-only.
    if ! cmp --silent -- "${doc}" "${doc_fmt}"; then
      log_err 'pre-commit table in docs/development/git.md is stale. Run scripts/refresh-precommit-table.sh and commit.'
      exit 1
    fi
    log_info 'pre-commit table in docs/development/git.md is up to date'
    return 0
  fi

  mv -- "${doc_fmt}" "${doc}"
  log_info 'refreshed pre-commit table in docs/development/git.md'
}

main "$@"
