#!/usr/bin/env bash
# tests/lib-log.test.sh — proves scripts/lib/log.sh reports the real
# exit code (the date-substitution $? clobber is fixed) and that
# require_tool reports an absent tool as a could-not-run condition.
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
LIB="${REPO_ROOT}/scripts/lib/log.sh"
failures=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# A throwaway script that sources the lib and fails deliberately.
work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT
cat >"${work}/boom.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=\$'\n\t'
source "${LIB}"
false            # trips the ERR trap on this line
EOF
chmod +x "${work}/boom.sh"

err="$(mktemp)"
out="$(mktemp)"
outcome="$(mktemp)"
rc=0
"${work}/boom.sh" >"${out}" 2>"${err}" || rc=$?
printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${outcome}"
# The two assertions below are an extended-regexp match and a
# must-not-appear check; neither is a fixed-string assertion the gate can
# audit, so the scenario contributes its output with no asserted substring.
harness_assert_record 'ERR trap logs the real non-zero exit code' '' \
  "${outcome}" "${out}" "${err}"

if [[ ${rc} -ne 0 ]] && grep -Eq 'exit [1-9][0-9]*' "${err}"; then
  pass 'ERR trap logs the real non-zero exit code'
else
  fail "expected non-zero exit + 'exit <n>' in trap output; rc=${rc}"
  cat -- "${err}" >&2
fi
if grep -q 'exit 0' "${err}"; then
  fail 'trap still logs "exit 0" — the $? clobber is not fixed'
fi

# require_tool must exit 2, not 1: an absent tool means the caller could
# not run at all. A caller reserving exit 1 for a violation it found — a
# freshness hook's "the doc is stale, regenerate and commit" — would
# otherwise send the operator to regenerate a doc over a missing binary.
cat >"${work}/needs_tool.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=\$'\n\t'
source "${LIB}"
require_tool definitely-not-a-real-tool-xyz
EOF
chmod +x "${work}/needs_tool.sh"

tool_err="$(mktemp)"
tool_out="$(mktemp)"
tool_outcome="$(mktemp)"
tool_rc=0
"${work}/needs_tool.sh" >"${tool_out}" 2>"${tool_err}" || tool_rc=$?
printf 'harness-assert-outcome: exit=%d\n' "${tool_rc}" >"${tool_outcome}"
harness_assert_record 'require_tool reports an absent tool' \
  'missing required tool' "${tool_outcome}" "${tool_out}" "${tool_err}"
if [[ ${tool_rc} -eq 2 ]] &&
  grep --fixed-strings --quiet -- 'missing required tool' "${tool_err}"; then
  pass 'require_tool exits 2 with a missing-tool message'
else
  fail "require_tool: expected exit 2 + 'missing required tool', got exit ${tool_rc}"
  cat -- "${tool_err}" >&2
fi
rm --force -- "${tool_err}" "${tool_out}" "${tool_outcome}"

# A stripped PATH must not degrade the log line. The timestamp comes from
# a shell builtin, so an absent `date` changes nothing an operator reads:
# no `command not found` noise, and a real timestamp rather than an empty
# bracket. A library that shells out for its timestamp turns every
# diagnostic under a broken PATH into three lines of tooling failure
# ahead of the message the operator needs.
cat >"${work}/logline.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=\$'\n\t'
source "${LIB}"
log_err 'canary message'
EOF
chmod +x "${work}/logline.sh"

stripped_err="$(mktemp)"
stripped_out="$(mktemp)"
stripped_outcome="$(mktemp)"
stripped_rc=0
env --unset=BASH_ENV PATH=/nonexistent /usr/bin/bash "${work}/logline.sh" \
  >"${stripped_out}" 2>"${stripped_err}" || stripped_rc=$?
printf 'harness-assert-outcome: exit=%d\n' "${stripped_rc}" >"${stripped_outcome}"
harness_assert_record 'log line survives a stripped PATH' 'canary message' \
  "${stripped_outcome}" "${stripped_out}" "${stripped_err}"

if grep -q 'command not found' "${stripped_err}"; then
  fail 'log emitted a command-not-found line under a stripped PATH'
elif ! grep -Eq '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4}\] ERROR canary message$' "${stripped_err}"; then
  fail "expected a timestamped ERROR line under a stripped PATH; got: $(cat -- "${stripped_err}")"
else
  pass 'log line survives a stripped PATH'
fi

harness_assert_verify || failures=$((failures + 1))

[[ ${failures} -eq 0 ]] || {
  printf '%d failure(s)\n' "${failures}" >&2
  exit 1
}
printf 'all passed\n'
