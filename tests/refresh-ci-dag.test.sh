#!/usr/bin/env bash
# tests/refresh-ci-dag.test.sh
#
# Round-trip + drift harness for scripts/refresh-ci-dag.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
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

  # Scenario 7: an absent input doc exits 2, not 1. The generator splices
  # into the doc rather than writing it from scratch, so a missing doc
  # means the check could not run — exit 1 would tell the operator the
  # doc is stale and to regenerate it, which reads nothing.
  local missing_doc missing_err missing_out missing_outcome missing_rc=0
  missing_doc="$(mktemp --directory)/absent-ci-dag.md"
  missing_err="$(mktemp)"
  missing_out="$(mktemp)"
  missing_outcome="$(mktemp)"
  CI_WORKFLOW_OVERRIDE="${FIXTURES}/no-needs/ci.yml" \
    CATEGORIES_FILE_OVERRIDE="${FIXTURES}/categories.yml" \
    DOC_OVERRIDE="${missing_doc}" \
    "${SCRIPT}" --check >"${missing_out}" 2>"${missing_err}" || missing_rc=$?
  rmdir -- "$(dirname -- "${missing_doc}")"
  printf 'harness-assert-outcome: exit=%d\n' "${missing_rc}" >"${missing_outcome}"
  harness_assert_record 'absent input doc rejected' \
    'not found' "${missing_outcome}" "${missing_out}" "${missing_err}"
  if [[ ${missing_rc} -eq 2 ]] &&
    grep --fixed-strings --quiet -- 'not found' "${missing_err}"; then
    pass 'absent input doc exits 2 (could not run, not drift)'
  else
    fail "missing-doc guard: expected exit 2 + 'not found', got exit ${missing_rc}"
    cat -- "${missing_err}" >&2
  fi
  rm --force -- "${missing_err}" "${missing_out}" "${missing_outcome}"

  # Markers the anchored awk splice cannot match (trailing whitespace on both
  # markers) must be rejected by the guard, not silently emitted unchanged.
  # An unanchored guard grep false-greens here; the anchored guard fails
  # closed with a marker-missing message.
  local ws_backup ws_err ws_out ws_outcome ws_rc=0
  ws_backup="$(mktemp)"
  ws_err="$(mktemp)"
  ws_out="$(mktemp)"
  ws_outcome="$(mktemp)"
  cp -- "${DOC}" "${ws_backup}"
  sed -e 's/^<!-- BEGIN ci-dag -->$/<!-- BEGIN ci-dag --> /' \
    -e 's/^<!-- END ci-dag -->$/<!-- END ci-dag --> /' \
    "${ws_backup}" >"${DOC}"
  "${SCRIPT}" --check >"${ws_out}" 2>"${ws_err}" || ws_rc=$?
  cp -- "${ws_backup}" "${DOC}"
  printf 'harness-assert-outcome: exit=%d\n' "${ws_rc}" >"${ws_outcome}"
  harness_assert_record 'whitespace-perturbed markers rejected' \
    'marker missing' "${ws_outcome}" "${ws_out}" "${ws_err}"
  if [[ ${ws_rc} -eq 1 ]] &&
    grep --fixed-strings --quiet -- 'marker missing' "${ws_err}"; then
    pass 'whitespace-perturbed markers rejected (fail-closed, not false-green)'
  else
    fail "whitespace marker guard: expected exit 1 + 'marker missing', got exit ${ws_rc}"
    cat -- "${ws_err}" >&2
  fi
  rm --force -- "${ws_backup}" "${ws_err}" "${ws_out}" "${ws_outcome}"

  # A jq failure at the job-key read must abort with its own message
  # rather than render a graph missing every node. No workflow input
  # reaches that call — the yq extract and the dangling-needs jq both
  # read the same job map first and fail earlier — so the guard is
  # exercised with a jq stub that fails only for the bare `keys[]`
  # filter and execs the real jq otherwise. A blanket-failing stub would
  # trip the dangling-needs jq first and green for the wrong reason,
  # which is why the assertion checks the message and not just the code.
  local stub_dir jq_err jq_out jq_outcome real_jq jq_rc=0
  real_jq="$(command -v jq)"
  stub_dir="$(mktemp --directory)"
  jq_err="$(mktemp)"
  jq_out="$(mktemp)"
  jq_outcome="$(mktemp)"
  cat >"${stub_dir}/jq" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ \${arg} == 'keys[]' ]]; then
    printf 'stub jq: refusing the bare keys[] filter\n' >&2
    exit 9
  fi
done
exec ${real_jq} "\$@"
EOF
  chmod +x -- "${stub_dir}/jq"
  tmpdoc="$(mktemp --suffix=.md)"
  cat >"${tmpdoc}" <<'EOF'
<!-- BEGIN ci-dag -->
<!-- END ci-dag -->
EOF
  PATH="${stub_dir}:${PATH}" \
    CI_WORKFLOW_OVERRIDE="${FIXTURES}/no-needs/ci.yml" \
    CATEGORIES_FILE_OVERRIDE="${FIXTURES}/categories.yml" \
    DOC_OVERRIDE="${tmpdoc}" \
    "${SCRIPT}" --check >"${jq_out}" 2>"${jq_err}" || jq_rc=$?
  rm --force -- "${tmpdoc}"
  tmpdoc=''
  rm --recursive --force -- "${stub_dir}"
  printf 'harness-assert-outcome: exit=%d\n' "${jq_rc}" >"${jq_outcome}"
  harness_assert_record 'jq job-key read failure aborts' \
    'could not read job keys with jq' "${jq_outcome}" "${jq_out}" "${jq_err}"
  if [[ ${jq_rc} -eq 2 ]] && grep --fixed-strings --quiet -- \
    'could not read job keys with jq' "${jq_err}"; then
    pass 'jq failure at job-key read exits 2 with its own message'
  else
    fail "jq job-key guard: expected exit 2 + 'could not read job keys with jq', got exit ${jq_rc}"
    cat -- "${jq_err}" >&2
  fi
  rm --force -- "${jq_err}" "${jq_out}" "${jq_outcome}"

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '%d failure(s)\n' "${failures}" >&2
    exit 1
  fi
  printf 'all passed\n'
}

main "$@"
