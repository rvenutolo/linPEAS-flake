# scripts/lib/payload.sh
#
# @description Shape gate for an externally-supplied JSON payload.
# Source after `set -Eeuo pipefail` and after `lib/log.sh`.
# shellcheck shell=bash

# @description Reject a payload whose shape the reads below cannot rely
# on, as a could-not-run rather than as a finding.
#
# A payload arriving from an API response, a tool's JSON output, or a
# file written by automation carries no shape guarantee. Reading one
# unguarded surfaces a malformed payload two ways, both wrong: `jq` dies
# with a raw diagnostic under an exit code the convention does not
# catalogue, or — worse — an absent field reads as an empty string and
# the caller reports substantive drift. Exit 1 sends a maintainer after
# posture nobody changed, and the exit code alone does not tell the two
# apart.
#
# One gate in front of every read, rather than a guard per read: a read
# added later is then total by construction instead of depending on its
# author remembering the convention.
#
# The source is named by kind — an override variable name or an API path
# — never by fixture path. A fixture path in output lets two harness
# scenarios be told apart by their fixture rather than by their
# behavior.
#
# An empty or whitespace-only payload also fails the parse check below —
# `jq --exit-status` reports no-output as a failure regardless of why
# the input produced none — so this check is not what stands between
# such a payload and acceptance. It exists for diagnostic precision: a
# producer that wrote nothing and a producer that wrote garbage are
# different faults with different operator remedies, and the parse
# check's own diagnostic names only the garbage case.
#
# @arg $1 source kind, used verbatim in every diagnostic
# @arg $2 the payload
# @arg $3 optional jq program emitting a message for the first field
#   whose type is wrong, and `empty` when the shape is acceptable
# @exitcode 2 the payload is empty, unparsable, or the shape program
#   named a fault
function require_json_payload() {
  local -r __payload_source="$1" __payload="$2" __shape_prog="${3:-}"
  require_tool jq

  if [[ -z ${__payload//[[:space:]]/} ]]; then
    printf 'empty payload from %s\n' "${__payload_source}" >&2
    exit 2
  fi

  if ! jq --exit-status type >/dev/null 2>&1 <<<"${__payload}"; then
    printf 'payload from %s is not valid JSON\n' "${__payload_source}" >&2
    exit 2
  fi

  [[ -n ${__shape_prog} ]] || return 0

  # Captured with its status checked rather than read through a process
  # substitution, whose exit status stays in its own subshell: a jq
  # failure would otherwise yield an empty message and score the payload
  # acceptable — the gate vouching for exactly what it exists to catch.
  local __shape_error
  if ! __shape_error="$(jq --raw-output "${__shape_prog}" <<<"${__payload}" 2>/dev/null)"; then
    printf 'payload from %s could not be read for shape\n' "${__payload_source}" >&2
    exit 2
  fi
  if [[ -n ${__shape_error} ]]; then
    printf 'unexpected payload shape from %s: %s\n' \
      "${__payload_source}" "${__shape_error}" >&2
    exit 2
  fi
}
