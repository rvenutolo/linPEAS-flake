#!/usr/bin/env bash
# tests/lib-log.test.sh — proves scripts/lib/log.sh reports the real
# exit code (the date-substitution $? clobber is fixed).
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
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
rc=0
"${work}/boom.sh" >/dev/null 2>"${err}" || rc=$?

if [[ ${rc} -ne 0 ]] && grep -Eq 'exit [1-9][0-9]*' "${err}"; then
  pass 'ERR trap logs the real non-zero exit code'
else
  fail "expected non-zero exit + 'exit <n>' in trap output; rc=${rc}"
  cat -- "${err}" >&2
fi
if grep -q 'exit 0' "${err}"; then
  fail 'trap still logs "exit 0" — the $? clobber is not fixed'
fi

[[ ${failures} -eq 0 ]] || {
  printf '%d failure(s)\n' "${failures}" >&2
  exit 1
}
printf 'all passed\n'
