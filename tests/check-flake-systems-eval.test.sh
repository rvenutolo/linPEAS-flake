#!/usr/bin/env bash
# tests/check-flake-systems-eval.test.sh
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
SCRIPT="${REPO_ROOT}/scripts/check-flake-systems-eval.sh"
failures=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# @description Run the check with a given command line, assert its exit
# code and a substring of its stderr, and record the outcome for the
# cross-scenario discrimination gate.
# @arg $1 scenario name
# @arg $2 expected exit code
# @arg $3 expected stderr substring
# @arg $@ the arguments handed to the check
function run_arg_scenario() {
  local -r name="$1" expected_exit="$2" substring="$3"
  shift 3
  local arg_out arg_err arg_outcome arg_rc=0
  arg_out="$(mktemp)"
  arg_err="$(mktemp)"
  arg_outcome="$(mktemp)"
  "${SCRIPT}" "$@" >"${arg_out}" 2>"${arg_err}" || arg_rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${arg_rc}" >"${arg_outcome}"
  if [[ ${arg_rc} -eq ${expected_exit} ]] &&
    grep --fixed-strings --quiet -- "${substring}" "${arg_err}"; then
    pass "${name}"
  else
    fail "${name} — expected exit ${expected_exit} + ${substring}; rc=${arg_rc}"
    cat -- "${arg_err}" >&2
  fi
  harness_assert_record "${name}" "${substring}" \
    "${arg_outcome}" "${arg_out}" "${arg_err}"
  rm --force -- "${arg_out}" "${arg_err}" "${arg_outcome}"
}

# Assertion 1: guard passes against the real repo flake.
if "${SCRIPT}" >/dev/null 2>&1; then
  pass 'guard passes on the healthy repo flake'
else
  fail 'guard failed on the healthy repo flake'
fi

# Assertion 2: a fixture flake that declares a system whose output
# throws must fail with the system named in stderr.
fix="$(mktemp -d)"
trap 'rm -rf -- "${fix}"' EXIT
cat >"${fix}/flake.nix" <<'EOF'
{
  outputs = { self }: {
    lib.systems = [ "x86_64-linux" "bogus-system" ];
    packages."x86_64-linux".default = throw "unused";
    packages."bogus-system" = throw "system bogus-system is broken";
  };
}
EOF
(cd "${fix}" && git init -q && git add -A)
err="$(mktemp)"
out="$(mktemp)"
outcome="$(mktemp)"
rc=0
"${SCRIPT}" --flake "${fix}" >"${out}" 2>"${err}" || rc=$?
printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${outcome}"
if [[ ${rc} -ne 0 ]] && grep -q 'bogus-system' "${err}"; then
  pass 'guard fails and names the broken system'
else
  fail "expected non-zero + 'bogus-system' named; rc=${rc}"
  cat -- "${err}" >&2
fi
harness_assert_record 'guard fails and names the broken system' \
  'bogus-system' "${outcome}" "${out}" "${err}"

# Assertion 3: a fixture flake whose packages attrset enumerates fine but
# whose package *value* throws must fail. This is the case attribute-name
# forcing alone cannot see: the spine is intact, only the value is broken.
fix2="$(mktemp -d)"
cat >"${fix2}/flake.nix" <<'EOF'
{
  outputs = { self }: {
    lib.systems = [ "x86_64-linux" ];
    packages."x86_64-linux" = {
      good = derivation {
        name = "good";
        system = "x86_64-linux";
        builder = "/bin/sh";
      };
      broken = throw "package broken is not evaluable";
    };
  };
}
EOF
(cd "${fix2}" && git init -q && git add -A)
err2="$(mktemp)"
out2="$(mktemp)"
outcome2="$(mktemp)"
rc2=0
"${SCRIPT}" --flake "${fix2}" >"${out2}" 2>"${err2}" || rc2=$?
printf 'harness-assert-outcome: exit=%d\n' "${rc2}" >"${outcome2}"
if [[ ${rc2} -ne 0 ]] && grep -q 'package broken is not evaluable' "${err2}"; then
  pass 'guard fails on a per-package value throw'
else
  fail "expected non-zero + the throwing package's message; rc=${rc2}"
  cat -- "${err2}" >&2
fi
harness_assert_record 'guard fails on a per-package value throw' \
  'package broken is not evaluable' "${outcome2}" "${out2}" "${err2}"
rm -rf -- "${fix2}" "${err2}" "${out2}" "${outcome2}"

# Assertions 4-6: a run that evaluated nothing is a could-not-run, and
# every way of arriving there reports it the same. Exit 1 is reserved for
# a flake whose declared systems were evaluated and found wanting; a
# caller told 1 for an incomplete command line goes looking for a
# platform this repo dropped.
run_arg_scenario 'an unrecognized argument is a could-not-run' 2 \
  'unknown arg: --bogus' --bogus
run_arg_scenario 'a --flake with no directory is a could-not-run' 2 \
  '--flake needs a directory' --flake
# A directory holding no flake is the same class of fault one step later:
# nothing was evaluated, so nothing can be reported about the systems.
nonflake="$(mktemp -d)"
run_arg_scenario 'a flake whose systems cannot be read is a could-not-run' 2 \
  'cannot read' --flake "${nonflake}"
rm -rf -- "${nonflake}"

# Assertion 7: the one verdict on this path that is a finding rather than
# a could-not-run. The list was read and what it says is that nothing is
# declared, so the status check above it must not fold this case into the
# could-not-run beside it.
empty_systems="$(mktemp -d)"
cat >"${empty_systems}/flake.nix" <<'EOF'
{
  outputs = { self }: {
    lib.systems = [ ];
  };
}
EOF
(cd "${empty_systems}" && git init -q && git add -A)
run_arg_scenario 'a flake declaring no systems is a finding' 1 \
  'no systems in' --flake "${empty_systems}"
rm -rf -- "${empty_systems}"

harness_assert_verify || failures=$((failures + 1))

[[ ${failures} -eq 0 ]] || {
  printf '%d failure(s)\n' "${failures}" >&2
  exit 1
}
printf 'all passed\n'
