#!/usr/bin/env bash
# tests/refresh-scripts-reference.test.sh
#
# Round-trip + drift + hard-fail harness for
# scripts/refresh-scripts-reference.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/refresh-scripts-reference.sh"
readonly DOC="${REPO_ROOT}/docs/reference/scripts.md"

failures=0
function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Declared at top-level so the EXIT trap can reach across function boundaries.
backup=''
fixture_dir=''

function cleanup() {
  if [[ -n ${backup:-} && -f ${backup} ]]; then
    cp -- "${backup}" "${DOC}" 2>/dev/null || true
    rm --force -- "${backup}"
  fi
  if [[ -n ${fixture_dir:-} && -d ${fixture_dir} ]]; then
    rm --recursive --force -- "${fixture_dir}"
  fi
}
trap cleanup EXIT

function main() {
  # 1. Round trip: generate, then --check must pass.
  "${SCRIPT}"
  if "${SCRIPT}" --check; then
    pass '--check passes on freshly generated reference'
  else
    fail '--check failed right after generate'
  fi

  # 2. Markers + section H2s present.
  if grep --quiet '^<!-- BEGIN scripts-reference -->$' "${DOC}" &&
    grep --quiet '^<!-- END scripts-reference -->$' "${DOC}"; then
    pass 'BEGIN/END markers present'
  else
    fail 'BEGIN/END markers missing'
  fi

  if grep --quiet '^## Check scripts$' "${DOC}" &&
    grep --quiet '^## Refresh scripts$' "${DOC}" &&
    grep --quiet '^## Other$' "${DOC}"; then
    pass 'all three section H2s present'
  else
    fail 'one or more section H2s missing'
  fi

  # 3. Drift scenario: inject bogus H3 inside managed block.
  backup="$(mktemp)"
  cp -- "${DOC}" "${backup}"
  awk '
    { print }
    /^<!-- BEGIN scripts-reference -->$/ { print "### scripts/drift-injected.sh" }
  ' "${DOC}" >"${DOC}.tmp"
  mv -- "${DOC}.tmp" "${DOC}"
  local rc=0
  "${SCRIPT}" --check || rc=$?
  cp -- "${backup}" "${DOC}"
  rm --force -- "${backup}"
  backup=''
  if [[ ${rc} -eq 1 ]]; then
    pass '--check exits 1 on in-block drift'
  else
    fail "--check expected exit 1 on drift, got ${rc}"
  fi

  # 4. Hard-fail scenario: SCRIPTS_DIR_OVERRIDE points at a tmpdir
  # containing a fixture script with no @description; --check must
  # exit 2 (parser propagation).
  fixture_dir="$(mktemp --directory)"
  cat >"${fixture_dir}/no-desc.sh" <<'EOF'
#!/usr/bin/env bash
# no description annotation here.
set -Eeuo pipefail
echo hi
EOF
  rc=0
  SCRIPTS_DIR_OVERRIDE="${fixture_dir}" "${SCRIPT}" --check || rc=$?
  rm --recursive --force -- "${fixture_dir}"
  fixture_dir=''
  if [[ ${rc} -eq 2 ]]; then
    pass '--check exits 2 when fixture script lacks @description'
  else
    fail "--check expected exit 2 on missing @description, got ${rc}"
  fi

  if [[ ${failures} -gt 0 ]]; then
    printf '%d failure(s)\n' "${failures}" >&2
    exit 1
  fi
  printf 'all passed\n'
}

main "$@"
