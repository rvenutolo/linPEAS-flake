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
# @arg $4 optional subject, prefixed to every diagnostic as `<subject>: `.
#   A source kind does not always identify what could not be read: two
#   lints in this tree read different rulesets through one override
#   variable and one API route, so the source alone leaves an operator
#   unable to tell which subject's payload was malformed. Callers whose
#   source kind is unique to them pass nothing and their output is
#   unchanged.
# @exitcode 2 the payload is empty, unparsable, or the shape program
#   named a fault
function require_json_payload() {
  local -r __payload_source="$1" __payload="$2" __shape_prog="${3:-}"
  local -r __prefix="${4:+${4}: }"
  require_tool jq

  if [[ -z ${__payload//[[:space:]]/} ]]; then
    printf '%sempty payload from %s\n' "${__prefix}" "${__payload_source}" >&2
    exit 2
  fi

  if ! jq --exit-status type >/dev/null 2>&1 <<<"${__payload}"; then
    printf '%spayload from %s is not valid JSON\n' \
      "${__prefix}" "${__payload_source}" >&2
    exit 2
  fi

  [[ -n ${__shape_prog} ]] || return 0

  # Captured with its status checked rather than read through a process
  # substitution, whose exit status stays in its own subshell: a jq
  # failure would otherwise yield an empty message and score the payload
  # acceptable — the gate vouching for exactly what it exists to catch.
  local __shape_error
  if ! __shape_error="$(jq --raw-output "${__shape_prog}" <<<"${__payload}" 2>/dev/null)"; then
    printf '%spayload from %s could not be read for shape\n' \
      "${__prefix}" "${__payload_source}" >&2
    exit 2
  fi
  if [[ -n ${__shape_error} ]]; then
    printf '%sunexpected payload shape from %s: %s\n' \
      "${__prefix}" "${__payload_source}" "${__shape_error}" >&2
    exit 2
  fi
}

# @description Name a payload's source by kind, filling a caller variable.
#
# The rule every caller of `require_json_payload` needs first: a source is
# named by kind — the override variable's name when a fixture supplies the
# payload, the API route or the config's repo-relative name otherwise — and
# never by resolved path. A path in a diagnostic lets two harness scenarios
# be told apart by their fixture rather than by their behavior, which is
# what the census-parity gate exists to forbid.
#
# The result is written into a caller variable rather than printed, because
# a function whose result is read as `$(...)` cannot fail. In argument
# position a command substitution discards its own status: the guard below
# would print, the shape gate would receive an empty source name, and the
# run would end 0. Filling a named variable keeps this function in the
# caller's shell, where `exit` ends the script that has the problem. This
# is the same reasoning the shape check above states for capturing its jq
# output instead of reading it through a process substitution.
#
# The override is resolved by indirect expansion rather than by an
# environment-only lookup, so that it is seen exactly as its consumer sees it:
# every caller reads its override with plain `${VAR:-}`, which sees a shell
# variable as well as an exported one. A namer blind to a variable its reader
# honors would name the fallback for a payload that did come from the
# override.
#
# The target is bound with a nameref rather than written with `printf -v`,
# so that a caller naming one of this function's own locals collides in the
# open — bash warns about the circular reference on stderr — where
# `printf -v` would write the local without a word and leave the caller's
# variable untouched. The locals carry a `__psrc_` prefix no call site uses,
# which keeps that collision theoretical. `scripts/lib/enumerate.sh` binds
# `enumerate_into`'s output the same way, so the two read alike.
#
# @arg $1 name of the caller variable to fill
# @arg $2 name of the override variable, exported or shell-scoped
# @arg $3 source name used when the override is unset or empty
# @exitcode 2 $2 is not a valid shell identifier
function payload_source_into() {
  local -r __psrc_out="$1" __psrc_ovr="$2" __psrc_fallback="$3"

  # Checked rather than assumed: indirect expansion of a non-identifier is
  # a fatal bash error, not an empty result, and this function's whole
  # value is that such a fault stops the caller under the exit code the
  # convention catalogues instead of naming an empty source.
  if [[ ! ${__psrc_ovr} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    printf '%s: payload_source_into: not a variable name: %s\n' \
      "${0##*/}" "${__psrc_ovr}" >&2
    exit 2
  fi

  local -n __psrc_ref="${__psrc_out}"
  if [[ -n ${!__psrc_ovr:-} ]]; then
    __psrc_ref="${__psrc_ovr}"
  else
    __psrc_ref="${__psrc_fallback}"
  fi
}

# @description Read a file payload into a caller variable, reporting a
# payload the caller could not read as a could-not-run rather than as a
# finding.
#
# The result is filled through a nameref rather than printed, for the
# reason `payload_source_into` states: a reader whose value is taken as
# `$(...)` cannot fail. A read that dies inside a command substitution
# leaves the caller assigning an empty string under a status it does not
# check, and the run continues into the shape gate, which then reports an
# empty payload — or, where the caller's own reads tolerate absence, into
# a drift verdict about posture nobody changed. Filling a named variable
# keeps `exit 2` in the shell that has the problem.
#
# Three conditions, three sentences: a payload that is absent, one whose
# permissions forbid the read, and one whose read fails for any other
# reason are different faults with different operator remedies. The third
# is not a catch-all for tidiness — a directory passes both the existence
# and the readable checks and fails only at the read itself, and it is
# the arm that stays exercisable where mode bits are no lever.
#
# The source is named by kind, never by resolved path, exactly as
# `require_json_payload` requires; pass the value `payload_source_into`
# filled.
#
# @arg $1 name of the caller variable to fill
# @arg $2 path to read
# @arg $3 source kind, used verbatim in every diagnostic
# @arg $4 optional subject, prefixed to every diagnostic as `<subject>: `
# @exitcode 2 the path is absent, unreadable, or the read failed
function read_json_payload_into() {
  local -r __pread_out="$1" __pread_path="$2" __pread_source="$3"
  local -r __pread_prefix="${4:+${4}: }"

  if [[ ! -e ${__pread_path} ]]; then
    printf '%spayload from %s not found\n' \
      "${__pread_prefix}" "${__pread_source}" >&2
    exit 2
  fi
  if [[ ! -r ${__pread_path} ]]; then
    printf '%spayload from %s is not readable\n' \
      "${__pread_prefix}" "${__pread_source}" >&2
    exit 2
  fi

  local -n __pread_ref="${__pread_out}"
  if ! __pread_ref="$(cat -- "${__pread_path}")"; then
    printf '%spayload from %s could not be read\n' \
      "${__pread_prefix}" "${__pread_source}" >&2
    exit 2
  fi
}
