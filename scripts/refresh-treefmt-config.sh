#!/usr/bin/env bash
# scripts/refresh-treefmt-config.sh
#
# @description Regenerate the treefmt-config managed block in
# docs/reference/treefmt-config.md from the enabled-formatter manifest
# exposed by `nix/treefmt-config.nix` as `devTooling.<system>.treefmtConfig`.
# @option --check exit 1 if the doc would change; exit 2 if the check
# cannot run (doc missing, or nix eval fails); do not mutate the working
# tree

# Replace the content between <!-- BEGIN treefmt-config --> and <!-- END treefmt-config -->
# in docs/reference/treefmt-config.md with the current set of enabled treefmt
# formatters (one row per formatter, with the file patterns each handles) plus
# a fenced list of global excludes.
#
# Usage:
#   scripts/refresh-treefmt-config.sh            # mutate docs/reference/treefmt-config.md in place
#   scripts/refresh-treefmt-config.sh --check    # exit 1 if the doc would change;
#                                                #   exit 2 if it cannot run;
#                                                #   do NOT mutate the working tree

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
cfg_file=''
raw_err=''
block_file=''
doc_new=''
doc_fmt=''

# @description Remove every temp file on exit, including any in-repo
# .refresh-treefmt-config-*.md siblings left by an interrupted earlier run.
function cleanup() {
  rm --force -- "${cfg_file}" "${raw_err}" "${block_file}" "${doc_new}" "${doc_fmt}"
  if [[ -n ${repo_root} ]]; then
    local stray
    shopt -s nullglob
    for stray in "${repo_root}"/.refresh-treefmt-config-*.md; do
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
  # this, mdformat-gfm's escape rules (e.g. backtick-wrapped globs containing
  # `*`) would cause the regenerated doc to differ from the committed file,
  # leaving treefmt-config-fresh red on every commit.
  require_tool treefmt

  local doc
  repo_root="$(git rev-parse --show-toplevel)"
  doc="${repo_root}/docs/reference/treefmt-config.md"
  readonly repo_root doc
  # Set before the temp files are made so even a failed `make_temp` triggers
  # the sibling sweep.
  # Signal handlers force exit (they do not on their own), which re-triggers the
  # EXIT trap so cleanup runs on Ctrl-C / SIGTERM / SIGHUP too.
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  # The doc is spliced, not written from scratch, so its absence is a
  # could-not-run condition rather than drift: exit 2 so the caller sends
  # the operator to the missing file instead of to a regenerate-and-commit.
  if [[ ! -f ${doc} ]]; then
    log_err "${doc} not found"
    exit 2
  fi
  if ! grep --quiet '^<!-- BEGIN treefmt-config -->$' "${doc}"; then
    log_err 'BEGIN marker missing from docs/reference/treefmt-config.md'
    exit 1
  fi
  if ! grep --quiet '^<!-- END treefmt-config -->$' "${doc}"; then
    log_err 'END marker missing from docs/reference/treefmt-config.md'
    exit 1
  fi

  cfg_file="$(make_temp)"
  raw_err="$(make_temp)"
  block_file="$(make_temp)"
  doc_new="$(make_temp)"
  # treefmt walks up to find flake.nix as projectRootFile, so the formatted
  # tmp file must live inside the repo. Hidden name + .md extension so
  # treefmt's mdformat picks it up; .gitignore keeps it untracked if a crash
  # bypasses the EXIT trap.
  doc_fmt="$(make_temp "${repo_root}/.refresh-treefmt-config-XXXXXX.md")"

  local sys
  sys="$(nix eval --impure --raw --expr 'builtins.currentSystem')"

  # Capture stderr (instead of discarding it) so harmless `trace:` messages
  # from treefmt-nix's evaluation do not corrupt the JSON payload on stdout,
  # while an eval failure still surfaces a readable diagnostic instead of a
  # blank one.
  if ! nix eval --json ".#devTooling.${sys}.treefmtConfig" >"${cfg_file}" 2>"${raw_err}"; then
    log_err 'nix eval failed:'
    cat -- "${raw_err}" >&2
    exit 2
  fi

  # Render the block: header row, separator, one row per formatter sorted by
  # name. Each glob is wrapped in backticks so mdformat-gfm renders patterns
  # like `*.sh` as inline code (and so the literal `*` is not interpreted as
  # markdown emphasis). Empty include / exclude lists render as an em dash
  # so the cell is non-empty.
  #
  # Global excludes render as a fenced list below the table to avoid
  # pipe-escape complications inside a single table cell.
  {
    printf '<!-- BEGIN treefmt-config -->\n'
    printf '\n'
    printf '| Formatter | Includes | Excludes |\n'
    printf '| --- | --- | --- |\n'
    jq --raw-output '
      def fmt_globs(arr):
        if (arr | length) == 0 then "—"
        else (arr | map("`" + . + "`") | join(" "))
        end;
      .formatters
      | sort_by(.name)[]
      | "| `" + .name + "` | " + fmt_globs(.includes) + " | " + fmt_globs(.excludes) + " |"
    ' "${cfg_file}"
    printf '\n'
    printf '## Global excludes\n'
    printf '\n'
    printf 'Patterns excluded from every formatter:\n'
    printf '\n'
    printf '```text\n'
    jq --raw-output '.globalExcludes | unique | sort[]' "${cfg_file}"
    printf '```\n'
    printf '\n'
    printf '<!-- END treefmt-config -->\n'
  } >"${block_file}"

  # Replace inclusive of markers (single occurrence). awk emits the block once
  # at the BEGIN marker, then suppresses every line until (and including) END.
  # Anchored to start-of-line so doc references to the marker do not falsely
  # match and emit the block twice.
  awk -v rep="${block_file}" '
    /^<!-- BEGIN treefmt-config -->$/ {
      while ((getline line < rep) > 0) print line
      close(rep)
      skip = 1
      next
    }
    /^<!-- END treefmt-config -->$/ {
      skip = 0
      next
    }
    !skip { print }
  ' "$(awk_path "${doc}")" >"${doc_new}"

  # Run treefmt over the regenerated doc so the comparison target matches
  # what the formatter chain (mdformat-gfm) would produce on commit. Without
  # this step, mdformat's escape rules cause persistent drift between the
  # script output and the committed file.
  cp -- "${doc_new}" "${doc_fmt}"
  treefmt --no-cache --quiet -- "${doc_fmt}" >/dev/null

  if [[ ${check_only} == 'true' ]]; then
    # cmp short-circuits on first byte difference and supports --silent across
    # both GNU and BSD coreutils — diff --quiet is GNU-only.
    if ! cmp --silent -- "${doc}" "${doc_fmt}"; then
      log_err 'treefmt-config block in docs/reference/treefmt-config.md is stale. Run scripts/refresh-treefmt-config.sh and commit.'
      exit 1
    fi
    log_info 'treefmt-config block in docs/reference/treefmt-config.md is up to date'
    return 0
  fi

  mv -- "${doc_fmt}" "${doc}"
  log_info 'refreshed treefmt-config block in docs/reference/treefmt-config.md'
}

main "$@"
