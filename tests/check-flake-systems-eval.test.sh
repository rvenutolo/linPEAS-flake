#!/usr/bin/env bash
# tests/check-flake-systems-eval.test.sh
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="${REPO_ROOT}/scripts/check-flake-systems-eval.sh"
failures=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
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
rc=0
"${SCRIPT}" --flake "${fix}" >/dev/null 2>"${err}" || rc=$?
if [[ ${rc} -ne 0 ]] && grep -q 'bogus-system' "${err}"; then
  pass 'guard fails and names the broken system'
else
  fail "expected non-zero + 'bogus-system' named; rc=${rc}"
  cat -- "${err}" >&2
fi

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
rc2=0
"${SCRIPT}" --flake "${fix2}" >/dev/null 2>"${err2}" || rc2=$?
if [[ ${rc2} -ne 0 ]] && grep -q 'x86_64-linux' "${err2}"; then
  pass 'guard fails on a per-package value throw'
else
  fail "expected non-zero + system named on value throw; rc=${rc2}"
  cat -- "${err2}" >&2
fi
rm -rf -- "${fix2}" "${err2}"

[[ ${failures} -eq 0 ]] || {
  printf '%d failure(s)\n' "${failures}" >&2
  exit 1
}
printf 'all passed\n'
