#!/usr/bin/env bash
# tests/lib-payload.test.sh — proves scripts/lib/payload.sh's
# require_json_payload treats an empty payload, a whitespace-only
# payload, an unparsable payload, a shape-program-rejected payload, and
# a shape program that itself errors evaluating the payload all as a
# could-not-run (exit 2, never exit 1), that a well-formed payload falls
# through with and without a shape program, and that an absent jq is
# reported the same way require_tool reports any other missing tool. It
# also proves payload_source_into fills its caller's variable with the
# override's own name whether that override is exported or shell-scoped,
# with the supplied fallback when the override is unset or empty, and
# that an override name that is not a shell identifier is a could-not-run
# that names no source at all.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly LOGLIB="${REPO_ROOT}/scripts/lib/log.sh"
readonly LIB="${REPO_ROOT}/scripts/lib/payload.sh"

failures=0
rc=0
work="$(mktemp --directory)"
trap 'rm --recursive --force -- "${work}"' EXIT

function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# @description Run require_json_payload in its own bash process — its
# could-not-run path calls `exit`, which must terminate only that
# process, not this harness — capture its streams, and record the
# outcome with the cross-scenario discrimination gate. Arguments travel
# through the child's environment rather than through string
# interpolation into the script text, so a payload holding quotes or
# whitespace needs no escaping at the call site.
# @arg $1 scenario name
# @arg $2 source kind (passed as require_json_payload's $1)
# @arg $3 payload (passed as $2)
# @arg $4 shape program (passed as $3; may be empty)
# @arg $5 canary text printed on the fall-through path
# @arg $6 asserted substring for the discrimination gate
# @arg $7 PATH override for the child process, or '' to keep the ambient PATH
function run_scenario() {
  local -r name="$1" source_kind="$2" payload="$3" shape_prog="$4" \
    canary="$5" substring="$6" path_override="$7"
  local -r script="${work}/${name}.sh"
  local -r out="${work}/${name}.out"
  local -r err="${work}/${name}.err"
  local -r outcome="${work}/${name}.outcome"
  cat >"${script}" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
source "${LOGLIB}"
source "${PAYLOADLIB}"
require_json_payload "${SOURCE_KIND}" "${PAYLOAD}" "${SHAPE_PROG}"
printf '%s\n' "${CANARY}"
SCRIPT
  chmod +x "${script}"
  rc=0
  if [[ -n ${path_override} ]]; then
    env --unset=BASH_ENV \
      PATH="${path_override}" \
      LOGLIB="${LOGLIB}" PAYLOADLIB="${LIB}" \
      SOURCE_KIND="${source_kind}" PAYLOAD="${payload}" \
      SHAPE_PROG="${shape_prog}" CANARY="${canary}" \
      /usr/bin/bash "${script}" >"${out}" 2>"${err}" || rc=$?
  else
    env \
      LOGLIB="${LOGLIB}" PAYLOADLIB="${LIB}" \
      SOURCE_KIND="${source_kind}" PAYLOAD="${payload}" \
      SHAPE_PROG="${shape_prog}" CANARY="${canary}" \
      bash "${script}" >"${out}" 2>"${err}" || rc=$?
  fi
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${outcome}"
  harness_assert_record "${name}" "${substring}" "${outcome}" "${out}" "${err}"
}

# The object-typed shape program shared by the two shape-driving
# scenarios: it names the first wrong-typed field via jq's `type`
# builtin, and emits `empty` — the shape-acceptable signal — for a real
# object.
readonly SHAPE_PROG='if type != "object" then "payload is \(type), want object" else empty end'

# 1. empty — a genuinely empty payload is a could-not-run, never a
# finding. The source kind is scenario-scoped rather than a constant
# shared with the whitespace scenario below: both trip the same
# emptiness branch and the diagnostic names only the source kind, so a
# shared kind would make the two scenarios' captured output
# byte-identical — a collapse the repo's discrimination gate holds at
# zero unless the pair is named on a reviewed allowlist, which this pair
# is not.
run_scenario 'empty' 'EMPTY_SOURCE' '' '' 'canary-empty' \
  'empty payload from EMPTY_SOURCE' ''
if [[ ${rc} -eq 2 ]] &&
  grep --fixed-strings --quiet -- 'empty payload from EMPTY_SOURCE' "${work}/empty.err"; then
  pass 'empty: an empty payload is exit 2, stderr names the source kind'
else
  fail "empty: expected exit 2 + 'empty payload from EMPTY_SOURCE', got exit ${rc}"
  cat -- "${work}/empty.out" "${work}/empty.err" >&2
fi

# 2. whitespace — a whitespace-only payload gets the same diagnostic as
# a genuinely empty one, which is what proves the emptiness check strips
# whitespace before testing length: `[[ -z ${payload} ]]` alone would
# treat this payload as non-empty and let it fall to the parse check
# below instead, which also rejects it (`jq --exit-status` reports
# no-output as a failure) but under that check's own "not valid JSON"
# diagnostic rather than this scenario's "empty payload" one.
run_scenario 'whitespace' 'WHITESPACE_SOURCE' '   ' '' 'canary-whitespace' \
  'empty payload from WHITESPACE_SOURCE' ''
if [[ ${rc} -eq 2 ]] &&
  grep --fixed-strings --quiet -- 'empty payload from WHITESPACE_SOURCE' "${work}/whitespace.err"; then
  pass 'whitespace: a whitespace-only payload is exit 2, not read as valid JSON'
else
  fail "whitespace: expected exit 2 + 'empty payload from WHITESPACE_SOURCE', got exit ${rc}"
  cat -- "${work}/whitespace.out" "${work}/whitespace.err" >&2
fi

# 3. unparsable — a non-empty payload that is not JSON is a
# could-not-run, not the raw `jq` parse diagnostic and not exit 5.
run_scenario 'unparsable' 'PARSE_SOURCE' 'not json' '' 'canary-unparsable' \
  'is not valid JSON' ''
if [[ ${rc} -eq 2 ]] &&
  grep --fixed-strings --quiet -- 'is not valid JSON' "${work}/unparsable.err"; then
  pass 'unparsable: unparsable JSON is exit 2, stderr names the fault'
else
  fail "unparsable: expected exit 2 + 'is not valid JSON', got exit ${rc}"
  cat -- "${work}/unparsable.out" "${work}/unparsable.err" >&2
fi

# 4. well-formed — a well-formed payload with no shape program falls
# through to the caller's own code, exit 0.
run_scenario 'well-formed' 'WELLFORMED_SOURCE' '{"a":1}' '' 'canary-well-formed' \
  'canary-well-formed' ''
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'canary-well-formed' "${work}/well-formed.out"; then
  pass 'well-formed: a well-formed payload with no shape program falls through, exit 0'
else
  fail "well-formed: expected exit 0 + fall-through canary, got exit ${rc}"
  cat -- "${work}/well-formed.out" "${work}/well-formed.err" >&2
fi

# 5. shape-reject — a shape program is given the chance to name a wrong
# type, and its message reaches the operator verbatim.
run_scenario 'shape-reject' 'SHAPE_REJECT_SOURCE' 'true' "${SHAPE_PROG}" \
  'canary-shape-reject' 'payload is boolean, want object' ''
if [[ ${rc} -eq 2 ]] &&
  grep --fixed-strings --quiet -- 'payload is boolean, want object' "${work}/shape-reject.err"; then
  pass 'shape-reject: a shape program rejecting the payload is exit 2, message reaches stderr'
else
  fail "shape-reject: expected exit 2 + 'payload is boolean, want object', got exit ${rc}"
  cat -- "${work}/shape-reject.out" "${work}/shape-reject.err" >&2
fi

# 6. shape-accept — the same shape program, given a payload of the right
# type, falls through same as the no-shape-program case.
run_scenario 'shape-accept' 'SHAPE_ACCEPT_SOURCE' '{"a":1}' "${SHAPE_PROG}" \
  'canary-shape-accept' 'canary-shape-accept' ''
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'canary-shape-accept' "${work}/shape-accept.out"; then
  pass 'shape-accept: a shape program accepting the payload falls through, exit 0'
else
  fail "shape-accept: expected exit 0 + fall-through canary, got exit ${rc}"
  cat -- "${work}/shape-accept.out" "${work}/shape-accept.err" >&2
fi

# 7. absent-jq — jq itself missing is a could-not-run reported by
# require_tool, the same shared helper every other library uses, not a
# bespoke diagnostic this library invents on its own.
run_scenario 'absent-jq' 'TOOL_SOURCE' '{"a":1}' '' 'canary-absent-jq' \
  'missing required tool: jq' '/nonexistent'
if [[ ${rc} -eq 2 ]] &&
  grep --fixed-strings --quiet -- 'missing required tool: jq' "${work}/absent-jq.err"; then
  pass 'absent-jq: a missing jq is exit 2 via require_tool, not a raw jq failure'
else
  fail "absent-jq: expected exit 2 + 'missing required tool: jq', got exit ${rc}"
  cat -- "${work}/absent-jq.out" "${work}/absent-jq.err" >&2
fi

# 8. shape-error — the shape program itself can fail independently of
# whether the payload is well-formed JSON: `.a.b` asks to index a number
# as an object, which is a well-formed JSON payload the shape program
# cannot evaluate. This is a distinct fault from shape-reject (5. above,
# where the shape program runs fine and reports the mismatch itself) and
# is what exercises the status check on the shape program's own jq
# invocation.
run_scenario 'shape-error' 'SHAPE_ERROR_SOURCE' '{"a":1}' '.a.b' \
  'canary-shape-error' 'could not be read for shape' ''
if [[ ${rc} -eq 2 ]] &&
  grep --fixed-strings --quiet -- 'payload from SHAPE_ERROR_SOURCE could not be read for shape' \
    "${work}/shape-error.err"; then
  pass 'shape-error: a shape program that itself errors is exit 2, names the source kind'
else
  fail "shape-error: expected exit 2 + 'payload from SHAPE_ERROR_SOURCE could not be read for shape', got exit ${rc}"
  cat -- "${work}/shape-error.out" "${work}/shape-error.err" >&2
fi

# @description Run payload_source_into in its own bash process — its
# guard path calls `exit`, which must terminate only that process, not
# this harness — capture its streams, and record the outcome with the
# cross-scenario discrimination gate. The child prints the filled
# variable on the success path, so a scenario proves the caller's
# variable was actually written rather than merely that the call returned
# 0: a helper that filled nothing would pass every exit-code assertion.
# Each scenario names a different source, because two scenarios naming
# one source produce one observable outcome between them and the gate
# scores such a pair as a single observation.
# @arg $1 scenario name
# @arg $2 how the override reaches the helper in the child: 'export',
#   'shell', 'empty', or 'unset'
# @arg $3 override variable name (passed as payload_source_into's $2)
# @arg $4 fallback source name (passed as $3)
# @arg $5 asserted substring for the discrimination gate
function run_source_into() {
  local -r name="$1" mode="$2" ovr_var="$3" fallback="$4" substring="$5"
  local -r script="${work}/${name}.sh"
  local -r out="${work}/${name}.out"
  local -r err="${work}/${name}.err"
  local -r outcome="${work}/${name}.outcome"
  cat >"${script}" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
source "${LOGLIB}"
source "${PAYLOADLIB}"
case "${MODE}" in
export) export "${OVR_VAR}=/fixtures/payload.json" ;;
shell)
  # Set at script scope with `declare` and then proven unexported. Every
  # caller reads its override with `${VAR:-}`, an expansion that honors a
  # shell variable, so the helper has to see one too; a setup that left
  # this variable exported would keep the scenario green against a helper
  # that only ever consults the environment.
  unset "${OVR_VAR}"
  declare "${OVR_VAR}=/fixtures/payload.json"
  if [[ $(declare -p "${OVR_VAR}") == 'declare -x'* ]]; then
    printf 'setup exported %s, so the shell-scoped override is not exercised\n' "${OVR_VAR}" >&2
    exit 3
  fi
  ;;
empty) export "${OVR_VAR}=" ;;
unset) unset "${OVR_VAR}" 2>/dev/null || true ;;
*)
  printf 'unknown mode: %s\n' "${MODE}" >&2
  exit 3
  ;;
esac
named_source=''
payload_source_into named_source "${OVR_VAR}" "${FALLBACK}"
printf 'named=%s\n' "${named_source}"
SCRIPT
  chmod +x "${script}"
  rc=0
  env \
    LOGLIB="${LOGLIB}" PAYLOADLIB="${LIB}" \
    MODE="${mode}" OVR_VAR="${ovr_var}" FALLBACK="${fallback}" \
    bash "${script}" >"${out}" 2>"${err}" || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${outcome}"
  harness_assert_record "${name}" "${substring}" "${outcome}" "${out}" "${err}"
}

# 9. source-into-exported-override — an override reaching the helper
# through the environment names the payload's source by the variable's
# own name, never by the path the variable holds.
run_source_into 'source-into-exported-override' export \
  RENOVATE_JSON_OVERRIDE 'renovate.json' 'named=RENOVATE_JSON_OVERRIDE'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --line-regexp --quiet -- 'named=RENOVATE_JSON_OVERRIDE' \
    "${work}/source-into-exported-override.out"; then
  pass 'source-into-exported-override: an exported override is named by its variable name'
else
  fail "source-into-exported-override: expected exit 0 + 'named=RENOVATE_JSON_OVERRIDE', got exit ${rc}"
  cat -- "${work}/source-into-exported-override.out" "${work}/source-into-exported-override.err" >&2
fi

# 10. source-into-shell-override — the same naming for an override that
# is only a shell variable. This is what pins the helper to indirect
# expansion: a `printenv`-based namer would miss this override and name
# the fallback for a payload that did come from the override, while every
# caller's own `${VAR:-}` read would have taken the override's path.
run_source_into 'source-into-shell-override' shell \
  PROTECT_MAIN_RULESET_JSON_OVERRIDE 'ruleset API' \
  'named=PROTECT_MAIN_RULESET_JSON_OVERRIDE'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --line-regexp --quiet -- 'named=PROTECT_MAIN_RULESET_JSON_OVERRIDE' \
    "${work}/source-into-shell-override.out"; then
  pass 'source-into-shell-override: a shell-scoped override is named by its variable name'
else
  fail "source-into-shell-override: expected exit 0 + 'named=PROTECT_MAIN_RULESET_JSON_OVERRIDE', got exit ${rc}"
  cat -- "${work}/source-into-shell-override.out" "${work}/source-into-shell-override.err" >&2
fi

# 11. source-into-unset-override — with no override set the caller's
# supplied source name is used verbatim, which is how an API route
# reaches a diagnostic.
run_source_into 'source-into-unset-override' unset \
  REPO_JSON_OVERRIDE '/repos/{owner}/{repo}' 'named=/repos/{owner}/{repo}'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --line-regexp --quiet -- 'named=/repos/{owner}/{repo}' \
    "${work}/source-into-unset-override.out"; then
  pass 'source-into-unset-override: an absent override falls back to the supplied source name'
else
  fail "source-into-unset-override: expected exit 0 + 'named=/repos/{owner}/{repo}', got exit ${rc}"
  cat -- "${work}/source-into-unset-override.out" "${work}/source-into-unset-override.err" >&2
fi

# 12. source-into-empty-override — an override set to the empty string
# falls back too. A namer keyed on the variable being *set* rather than
# on it being non-empty would name a source no payload came from, since
# the callers' own `${VAR:-fallback}` reads take the fallback here.
run_source_into 'source-into-empty-override' empty \
  FLAKE_LOCK_OVERRIDE 'flake.lock' 'named=flake.lock'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --line-regexp --quiet -- 'named=flake.lock' \
    "${work}/source-into-empty-override.out"; then
  pass 'source-into-empty-override: an empty override falls back to the supplied source name'
else
  fail "source-into-empty-override: expected exit 0 + 'named=flake.lock', got exit ${rc}"
  cat -- "${work}/source-into-empty-override.out" "${work}/source-into-empty-override.err" >&2
fi

# 13. source-into-bad-name — an override name that is not a shell
# identifier is a could-not-run. Both halves of this assertion are
# load-bearing: exit 2 alone would also hold for a guard that printed and
# let the caller continue, and the absence of any `named=` line is what
# proves no source was named. Without the guard, indirect expansion of a
# non-identifier is a fatal bash error under a status this repo's exit
# convention does not catalogue.
run_source_into 'source-into-bad-name' unset \
  'not a name' 'renovate.json' 'payload_source_into: not a variable name: not a name'
if [[ ${rc} -eq 2 ]] &&
  ! grep --fixed-strings --quiet -- 'named=' "${work}/source-into-bad-name.out"; then
  pass 'source-into-bad-name: a non-identifier override name is exit 2 and names no source'
else
  fail "source-into-bad-name: expected exit 2 and no 'named=' line, got exit ${rc}"
  cat -- "${work}/source-into-bad-name.out" "${work}/source-into-bad-name.err" >&2
fi

harness_assert_verify || failures=$((failures + 1))

if ((failures > 0)); then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
