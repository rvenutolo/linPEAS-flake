#!/usr/bin/env bash
# tests/lib-payload.test.sh — proves scripts/lib/payload.sh's
# require_json_payload treats an empty payload, a whitespace-only
# payload, an unparsable payload, and a shape-program-rejected payload
# all as a could-not-run (exit 2, never exit 1), that a well-formed
# payload falls through with and without a shape program, and that an
# absent jq is reported the same way require_tool reports any other
# missing tool.
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

# 2. whitespace — a whitespace-only payload is a could-not-run for the
# same reason an empty one is. jq reads whitespace-only input as no
# input at all and exits 0 on `jq --exit-status type`, so a check that
# tests `[[ -z ${payload} ]]` rather than stripping whitespace first
# would let this payload fall through the parse check as "valid JSON"
# and score a garbage payload clean — exactly the failure mode this
# library exists to close. This scenario is what proves the stripping.
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

harness_assert_verify || failures=$((failures + 1))

if ((failures > 0)); then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
