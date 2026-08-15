# scripts/lib/log.sh
#
# @description Shared logging + ERR-trap helpers for repo bash scripts.
# Source after `set -Eeuo pipefail`. The ERR trap captures the failing
# exit code as its first action: it is read into the format string before
# any other expansion, so nothing between the failure and the report can
# reset `$?`. Timestamps come from bash's `printf` time format, so no
# helper here needs a tool on PATH.
# shellcheck shell=bash

# @description Emit a timestamped level-tagged line to stderr.
# The timestamp comes from bash's own `printf` time format rather than
# `date`, so a diagnostic about a missing tool is not itself preceded by
# a `date: command not found` line and an empty timestamp. The format
# string is identical to the one `date` was given.
# @arg $1 level  @arg $2 message
function log() {
  local __log_ts
  printf -v __log_ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
  printf '[%s] %-5s %s\n' "${__log_ts}" "$1" "$2" >&2
}
function log_info() { log INFO "$*"; }
function log_err() { log ERROR "$*"; }

# @description Verify a required CLI tool is on PATH; exit 2 if missing.
# Exit 2 means "could not run", which is what an absent tool is; exit 1
# stays reserved for a violation the caller found. A freshness hook's
# caller reads exit 1 as "the doc is stale, run the generator and commit",
# so a missing jq reported as 1 sends the operator to regenerate a doc
# instead of to install jq.
# @arg $1 tool name
function require_tool() {
  local -r tool="$1"
  if ! command -v "${tool}" >/dev/null 2>&1; then
    log_err "missing required tool: ${tool}"
    exit 2
  fi
}

# @description Install the shared ERR trap in the calling shell. Captures
# the real failing exit code before any command substitution clobbers $?.
function install_err_trap() {
  # shellcheck disable=SC2154 # rc is assigned by this same trap string's
  # first statement; shellcheck does not trace intra-trap-string data flow
  trap 'rc=$?; printf "[%(%Y-%m-%dT%H:%M:%S%z)T] %-5s line %s (exit %s): %s\n" \
    -1 ERROR "${LINENO}" "${rc}" "${BASH_COMMAND}" >&2' ERR
}

# Sourcing this file installs the ERR trap immediately, so `source
# .../lib/log.sh` alone is sufficient. An explicit `install_err_trap`
# call after sourcing (the repo convention) is a harmless idempotent
# re-install — useful for a caller that needs to restore the trap
# after temporarily overriding it.
install_err_trap
