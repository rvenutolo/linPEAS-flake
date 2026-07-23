# scripts/lib/log.sh
#
# @description Shared logging + ERR-trap helpers for repo bash scripts.
# Source after `set -Eeuo pipefail`. The ERR trap captures the failing
# exit code as its first action, before any command substitution — a
# later `$(date ...)` would otherwise reset `$?` to zero and mask the
# real code.
# shellcheck shell=bash

# @description Emit a timestamped level-tagged line to stderr.
# @arg $1 level  @arg $2 message
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

# @description Install the shared ERR trap in the calling shell. Captures
# the real failing exit code before any command substitution clobbers $?.
function install_err_trap() {
  # shellcheck disable=SC2154 # rc is assigned by this same trap string's
  # first statement; shellcheck does not trace intra-trap-string data flow
  trap 'rc=$?; printf "[%s] %-5s line %s (exit %s): %s\n" \
    "$(date "+%Y-%m-%dT%H:%M:%S%z")" ERROR "${LINENO}" "${rc}" "${BASH_COMMAND}" >&2' ERR
}

# Sourcing this file installs the ERR trap immediately, so `source
# .../lib/log.sh` alone is sufficient. An explicit `install_err_trap`
# call after sourcing (the repo convention) is a harmless idempotent
# re-install — useful for a caller that needs to restore the trap
# after temporarily overriding it.
install_err_trap
