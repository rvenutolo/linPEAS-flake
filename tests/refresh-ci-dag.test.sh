#!/usr/bin/env bash
# tests/refresh-ci-dag.test.sh
#
# Round-trip + drift harness for scripts/refresh-ci-dag.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/refresh-ci-dag.sh"
readonly DOC="${REPO_ROOT}/docs/architecture/ci-dag.md"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/refresh-ci-dag"

failures=0
function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Top-level so the EXIT trap can reach them across function boundaries.
backup=''
tmpdoc=''

function cleanup() {
  if [[ -n ${backup} && -f ${backup} ]]; then
    cp -- "${backup}" "${DOC}" 2>/dev/null || true
    rm --force -- "${backup}"
  fi
  if [[ -n ${tmpdoc} && -f ${tmpdoc} ]]; then
    rm --force -- "${tmpdoc}"
  fi
}
trap cleanup EXIT

function main() {
  # Scenario 1: real-repo --check passes after a fresh generate.
  "${SCRIPT}"
  if "${SCRIPT}" --check; then
    pass '--check passes on freshly generated block in real repo'
  else
    fail '--check failed right after generate'
  fi

  # Scenario 2: in-block drift makes --check exit non-zero (real repo).
  backup="$(mktemp)"
  cp -- "${DOC}" "${backup}"
  awk '
    { print }
    /^<!-- BEGIN ci-dag -->$/ { print "  drift-node:::aux" }
  ' "${DOC}" >"${DOC}.tmp"
  mv -- "${DOC}.tmp" "${DOC}"
  local rc=0
  "${SCRIPT}" --check || rc=$?
  cp -- "${backup}" "${DOC}"
  rm --force -- "${backup}"
  backup=''
  if [[ ${rc} -ne 0 ]]; then
    pass '--check fails on in-block drift'
  else
    fail '--check passed despite in-block drift'
  fi

  # Scenario 3: dangling-need fixture exits 2.
  tmpdoc="$(mktemp --suffix=.md)"
  cat >"${tmpdoc}" <<'EOF'
<!-- BEGIN ci-dag -->
<!-- END ci-dag -->
EOF
  local rc2=0
  CI_WORKFLOW_OVERRIDE="${FIXTURES}/dangling-need/ci.yml" \
    CATEGORIES_FILE_OVERRIDE="${FIXTURES}/categories.yml" \
    DOC_OVERRIDE="${tmpdoc}" \
    "${SCRIPT}" --check || rc2=$?
  rm --force -- "${tmpdoc}"
  tmpdoc=''
  if [[ ${rc2} -eq 2 ]]; then
    pass 'dangling-need fixture exits 2'
  else
    fail "dangling-need fixture exit was ${rc2}, want 2"
  fi

  # Scenario 4: no-needs fixture regenerates to the frozen golden.
  tmpdoc="$(mktemp --suffix=.md)"
  cat >"${tmpdoc}" <<'EOF'
<!-- BEGIN ci-dag -->
<!-- END ci-dag -->
EOF
  CI_WORKFLOW_OVERRIDE="${FIXTURES}/no-needs/ci.yml" \
    CATEGORIES_FILE_OVERRIDE="${FIXTURES}/categories.yml" \
    DOC_OVERRIDE="${tmpdoc}" \
    "${SCRIPT}" >/dev/null
  if cmp --silent -- "${tmpdoc}" "${FIXTURES}/no-needs/expected.md"; then
    pass 'no-needs fixture matches frozen expected.md byte-for-byte'
  else
    fail 'no-needs fixture diverges from expected.md'
    diff -u -- "${FIXTURES}/no-needs/expected.md" "${tmpdoc}" >&2 || true
  fi
  rm --force -- "${tmpdoc}"
  tmpdoc=''

  # Scenario 5: with-needs fixture (incl a scalar needs:) renders edges to golden.
  tmpdoc="$(mktemp --suffix=.md)"
  cat >"${tmpdoc}" <<'EOF'
<!-- BEGIN ci-dag -->
<!-- END ci-dag -->
EOF
  CI_WORKFLOW_OVERRIDE="${FIXTURES}/with-needs/ci.yml" \
    CATEGORIES_FILE_OVERRIDE="${FIXTURES}/categories.yml" \
    DOC_OVERRIDE="${tmpdoc}" \
    "${SCRIPT}" >/dev/null
  if cmp --silent -- "${tmpdoc}" "${FIXTURES}/with-needs/expected.md"; then
    pass 'with-needs fixture renders edges (incl scalar needs) byte-for-byte'
  else
    fail 'with-needs fixture diverges from expected.md'
    diff -u -- "${FIXTURES}/with-needs/expected.md" "${tmpdoc}" >&2 || true
  fi
  rm --force -- "${tmpdoc}"
  tmpdoc=''

  # Scenario 6: unknown arg exits 2 (arg parse precedes any file I/O).
  local rc3=0
  "${SCRIPT}" --bogus-arg >/dev/null 2>&1 || rc3=$?
  if [[ ${rc3} -eq 2 ]]; then
    pass 'unknown arg exits 2'
  else
    fail "unknown arg exit was ${rc3}, want 2"
  fi

  if [[ ${failures} -gt 0 ]]; then
    printf '%d failure(s)\n' "${failures}" >&2
    exit 1
  fi
  printf 'all passed\n'
}

main "$@"
