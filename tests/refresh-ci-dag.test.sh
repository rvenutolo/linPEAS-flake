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

# @description Render one workflow holding job-a and a job under the
# given key, with the given category map, and require the key's node to
# take the Doc quality class and job-a the build class, and the run to log
# only its one line (yq's own warning about a merge key aside).
# @arg $1 work dir  @arg $2 case name  @arg $3 job key  @arg $4 category map
function ci_dag_key_case() {
  local -r work="$1" case_name="$2" key="$3" cats="$4"
  local key_rc=0 err
  printf "name: ci\non: push\njobs:\n  job-a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: \"true\"\n  '%s':\n    runs-on: ubuntu-latest\n    steps:\n      - run: \"true\"\n" \
    "${key//\'/\'\'}" >"${work}/${case_name}.yml"
  printf '%s' "${cats}" >"${work}/${case_name}.cats.yml"
  printf '<!-- BEGIN ci-dag -->\n<!-- END ci-dag -->\n' >"${work}/${case_name}.md"
  PROBE=PAYLOAD_RAN PROBE_FILE="${work}/probe.txt" \
    CI_WORKFLOW_OVERRIDE="${work}/${case_name}.yml" \
    CATEGORIES_FILE_OVERRIDE="${work}/${case_name}.cats.yml" \
    DOC_OVERRIDE="${work}/${case_name}.md" \
    "${SCRIPT}" >"${work}/${case_name}.out" 2>"${work}/${case_name}.err" || key_rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${key_rc}" >"${work}/${case_name}.outcome"
  harness_assert_record "job key as data: ${case_name}" '' \
    "${work}/${case_name}.outcome" "${work}/${case_name}.md" "${work}/${case_name}.err"
  err="$(grep --invert-match --fixed-strings -- '--yaml-fix-merge-anchor-to-spec' "${work}/${case_name}.err" || true)"
  if [[ ${key_rc} -eq 0 ]] &&
    [[ ${err} =~ ^\[[^]]*\]\ INFO\ \ refreshed\ ci-dag\ block\ in\ (.*)$ ]] &&
    [[ ${BASH_REMATCH[1]} == "${work}/${case_name}.md" ]] &&
    grep --line-regexp --fixed-strings --quiet -- "  ${key}:::doc" "${work}/${case_name}.md" &&
    grep --line-regexp --fixed-strings --quiet -- '  job-a:::build' "${work}/${case_name}.md"; then
    pass "job key as data: ${case_name} renders its own category"
  else
    fail "job key as data: ${case_name}: exit ${key_rc}, want 0 and the line '  ${key}:::doc'"
    cat -- "${work}/${case_name}.err" "${work}/${case_name}.md" >&2
  fi
}

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

  # A workflow that does not parse is an input the generator could not
  # read: exit 2, not the exit 1 that reads as a diagram gone stale.
  local bad_wf bad_err bad_out bad_outcome bad_rc=0
  bad_wf="$(mktemp)"
  bad_err="$(mktemp)"
  bad_out="$(mktemp)"
  bad_outcome="$(mktemp)"
  printf 'jobs: [\n' >"${bad_wf}"
  CI_WORKFLOW_OVERRIDE="${bad_wf}" \
    CATEGORIES_FILE_OVERRIDE="${FIXTURES}/categories.yml" \
    "${SCRIPT}" --check >"${bad_out}" 2>"${bad_err}" || bad_rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${bad_rc}" >"${bad_outcome}"
  harness_assert_record 'unparsable workflow rejected' \
    "could not read the job graph from ${bad_wf}" "${bad_outcome}" "${bad_out}" "${bad_err}"
  if [[ ${bad_rc} -eq 2 ]] &&
    grep --fixed-strings --quiet -- "could not read the job graph from ${bad_wf}" "${bad_err}"; then
    pass 'unparsable workflow exits 2 (could not run, not drift)'
  else
    fail "unparsable-workflow guard: expected exit 2, got exit ${bad_rc}"
    sed 's/^/    /' "${bad_err}" >&2
  fi
  rm --force -- "${bad_wf}" "${bad_err}" "${bad_out}" "${bad_outcome}"

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

  # Scenario: a job key is data, never expression text. Each key below
  # closes a quoted segment if spliced into the category read: it would
  # take job-a's category, or print an environment variable or a file
  # through `error()`, or match job-a as a pattern. Read as data, each
  # key takes its own category and the run logs only its one line. The
  # key's own entry comes first, so a pattern that also matched job-a
  # would end on job-a's.
  local key_work
  key_work="$(mktemp --directory)"
  printf 'FILE_READ_MARK\n' >"${key_work}/probe.txt"
  local -a key_cases=(
    'reads-other' 'zz" // ."job-a'
    'reads-env' 'zz" | error(strenv(PROBE)) | ."y'
    'reads-file' 'zz" | error(load_str(strenv(PROBE_FILE))) | ."y'
    'wildcard' 'job-*'
  )
  local i quoted
  for ((i = 0; i < ${#key_cases[@]}; i += 2)); do
    quoted=${key_cases[i + 1]//\'/\'\'}
    ci_dag_key_case "${key_work}" "${key_cases[i]}" "${key_cases[i + 1]}" \
      "'${quoted}': Doc quality"$'\njob-a: Build + smoke\n'
  done
  # A category a merge key brings in is read, and of a job written twice
  # in the map the last entry is read, as yq's own lookup reads them.
  ci_dag_key_case "${key_work}" 'through-merge' 'job-m' \
    $'x-base: &base\n  job-m: Doc quality\n<<: *base\njob-a: Build + smoke\n'
  ci_dag_key_case "${key_work}" 'written-twice' 'job-d' \
    $'job-d: Build + smoke\njob-d: Doc quality\njob-a: Build + smoke\n'
  # A job key the job list cannot carry, and a merge key under `jobs:`,
  # stop the run (exit 2) naming the file, and the diagram is untouched:
  # a line break renders as two nodes, an empty key as none, and a merge
  # key as the node `<<`.
  local refused_name refused_body refused_rc refused_err
  local -a refused_cases=(
    'refused-line-break' $'jobs:\n  "a\\nb":\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n'
    'refused-empty' $'jobs:\n  "":\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n'
    'refused-merge-key' $'x: &base\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\njobs:\n  <<: *base\n'
  )
  for ((i = 0; i < ${#refused_cases[@]}; i += 2)); do
    refused_name=${refused_cases[i]}
    refused_body=${refused_cases[i + 1]}
    printf 'name: ci\non: push\n%s' "${refused_body}" >"${key_work}/${refused_name}.yml"
    printf 'job-a: Build + smoke\n' >"${key_work}/${refused_name}.cats.yml"
    printf '<!-- BEGIN ci-dag -->\n<!-- END ci-dag -->\n' >"${key_work}/${refused_name}.md"
    cp -- "${key_work}/${refused_name}.md" "${key_work}/${refused_name}.md.orig"
    refused_rc=0
    CI_WORKFLOW_OVERRIDE="${key_work}/${refused_name}.yml" CATEGORIES_FILE_OVERRIDE="${key_work}/${refused_name}.cats.yml" \
      DOC_OVERRIDE="${key_work}/${refused_name}.md" \
      "${SCRIPT}" >"${key_work}/${refused_name}.out" 2>"${key_work}/${refused_name}.err" || refused_rc=$?
    printf 'harness-assert-outcome: exit=%d\n' "${refused_rc}" >"${key_work}/${refused_name}.outcome"
    harness_assert_record "job key refused: ${refused_name}" 'which GitHub Actions refuses' \
      "${key_work}/${refused_name}.outcome" "${key_work}/${refused_name}.out" "${key_work}/${refused_name}.err"
    refused_err="$(grep --invert-match --fixed-strings -- '--yaml-fix-merge-anchor-to-spec' "${key_work}/${refused_name}.err" || true)"
    if [[ ${refused_rc} -eq 2 && ${refused_err} == *"${key_work}/${refused_name}.yml"*'which GitHub Actions refuses'* ]] &&
      cmp --silent -- "${key_work}/${refused_name}.md" "${key_work}/${refused_name}.md.orig"; then
      pass "job key refused: ${refused_name}"
    else
      fail "job key refused: ${refused_name}: exit ${refused_rc}, want 2 and a message naming the file"
      cat -- "${key_work}/${refused_name}.err" >&2
    fi
  done
  # A merge list inside a job is read first mapping wins, as the YAML
  # merge specification says: job ml-c takes the needs: of the mapping
  # listed first, so its one edge comes from ml-a.
  local ml_rc=0
  printf 'name: ci\non: push\nx-p: &P {needs: ml-a}\nx-q: &Q {needs: ml-b}\njobs:\n  ml-a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n  ml-b:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n  ml-c:\n    <<: [*P, *Q]\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n' >"${key_work}/ml.yml"
  printf 'ml-a: Build + smoke\nml-b: Build + smoke\nml-c: Doc quality\n' >"${key_work}/ml.cats.yml"
  printf '<!-- BEGIN ci-dag -->\n<!-- END ci-dag -->\n' >"${key_work}/ml.md"
  CI_WORKFLOW_OVERRIDE="${key_work}/ml.yml" CATEGORIES_FILE_OVERRIDE="${key_work}/ml.cats.yml" \
    DOC_OVERRIDE="${key_work}/ml.md" \
    "${SCRIPT}" >"${key_work}/ml.out" 2>"${key_work}/ml.err" || ml_rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${ml_rc}" >"${key_work}/ml.outcome"
  harness_assert_record 'merge list needs: first mapping wins' 'ml-a --> ml-c' \
    "${key_work}/ml.outcome" "${key_work}/ml.md" "${key_work}/ml.err"
  if [[ ${ml_rc} -eq 0 ]] && grep --fixed-strings --quiet -- 'ml-a --> ml-c' "${key_work}/ml.md" &&
    ! grep --fixed-strings --quiet -- 'ml-b --> ml-c' "${key_work}/ml.md"; then
    pass 'a merge list in a job is read first mapping wins'
  else
    fail "merge list needs: expected exit 0 and the edge ml-a --> ml-c only, got exit ${ml_rc}"
    cat -- "${key_work}/ml.md" >&2
  fi

  # A failing read of the job keys stops the run (exit 2) with the
  # generator's own message, even when every later read would succeed.
  # The shim fails only the read that prints keys as JSON.
  local keyread_stub keyread_rc=0 real_yq
  keyread_stub="$(mktemp --directory)"
  real_yq="$(command -v yq)"
  cat >"${keyread_stub}/yq" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ \${arg} == *'to_json(0)'* ]]; then
    exit 9
  fi
done
exec ${real_yq} "\$@"
EOF
  chmod +x -- "${keyread_stub}/yq"
  printf 'name: ci\non: push\njobs:\n  job-a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n' >"${key_work}/keyread.yml"
  printf 'job-a: Build + smoke\n' >"${key_work}/keyread.cats.yml"
  printf '<!-- BEGIN ci-dag -->\n<!-- END ci-dag -->\n' >"${key_work}/keyread.md"
  cp -- "${key_work}/keyread.md" "${key_work}/keyread.md.orig"
  PATH="${keyread_stub}:${PATH}" \
    CI_WORKFLOW_OVERRIDE="${key_work}/keyread.yml" CATEGORIES_FILE_OVERRIDE="${key_work}/keyread.cats.yml" \
    DOC_OVERRIDE="${key_work}/keyread.md" \
    "${SCRIPT}" >"${key_work}/keyread.out" 2>"${key_work}/keyread.err" || keyread_rc=$?
  rm --force -- "${keyread_stub}/yq"
  rmdir -- "${keyread_stub}"
  printf 'harness-assert-outcome: exit=%d\n' "${keyread_rc}" >"${key_work}/keyread.outcome"
  harness_assert_record 'job key read failure aborts' "could not read the job graph from ${key_work}/keyread.yml" \
    "${key_work}/keyread.outcome" "${key_work}/keyread.out" "${key_work}/keyread.err"
  if [[ ${keyread_rc} -eq 2 ]] &&
    grep --fixed-strings --quiet -- "could not read the job graph from ${key_work}/keyread.yml" "${key_work}/keyread.err" &&
    cmp --silent -- "${key_work}/keyread.md" "${key_work}/keyread.md.orig"; then
    pass 'a failing job-key read exits 2 with its own message'
  else
    fail "job-key read failure: expected exit 2 and the job graph message, got exit ${keyread_rc}"
    cat -- "${key_work}/keyread.err" >&2
  fi
  # A category map that is not one map of jobs stops the run (exit 2),
  # as a tool failing to read it does: a list's entries are keyed by
  # index, and every job would read as uncategorised.
  local shape_rc=0
  printf "name: ci\non: push\njobs:\n  job-a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: \"true\"\n" >"${key_work}/shape.yml"
  printf -- '- job-a: Build + smoke\n' >"${key_work}/shape.cats.yml"
  printf '<!-- BEGIN ci-dag -->\n<!-- END ci-dag -->\n' >"${key_work}/shape.md"
  cp -- "${key_work}/shape.md" "${key_work}/shape.md.orig"
  CI_WORKFLOW_OVERRIDE="${key_work}/shape.yml" CATEGORIES_FILE_OVERRIDE="${key_work}/shape.cats.yml" \
    DOC_OVERRIDE="${key_work}/shape.md" \
    "${SCRIPT}" >"${key_work}/shape.out" 2>"${key_work}/shape.err" || shape_rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${shape_rc}" >"${key_work}/shape.outcome"
  harness_assert_record 'category map that is a list' 'the category map must be one map of job names (got seq)' \
    "${key_work}/shape.outcome" "${key_work}/shape.out" "${key_work}/shape.err"
  if [[ ${shape_rc} -eq 2 ]] &&
    [[ $(<"${key_work}/shape.err") =~ ^\[[^]]*\]\ ERROR\ (.*)$ ]] &&
    [[ ${BASH_REMATCH[1]} == "${key_work}/shape.cats.yml: the category map must be one map of job names (got seq)" ]] &&
    cmp --silent -- "${key_work}/shape.md" "${key_work}/shape.md.orig"; then
    pass 'a category map that is a list exits 2 and leaves the doc alone'
  else
    fail "category map that is a list: exit ${shape_rc}, want 2"
    cat -- "${key_work}/shape.err" >&2
  fi
  # A category map of two documents stops the run the same way.
  shape_rc=0
  printf 'job-a: Build + smoke\n---\njob-a: Doc quality\n' >"${key_work}/shape.cats.yml"
  CI_WORKFLOW_OVERRIDE="${key_work}/shape.yml" CATEGORIES_FILE_OVERRIDE="${key_work}/shape.cats.yml" \
    DOC_OVERRIDE="${key_work}/shape.md" \
    "${SCRIPT}" >"${key_work}/shape2.out" 2>"${key_work}/shape2.err" || shape_rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${shape_rc}" >"${key_work}/shape2.outcome"
  harness_assert_record 'category map of two documents' 'the category map holds several YAML documents; it must hold one' \
    "${key_work}/shape2.outcome" "${key_work}/shape2.out" "${key_work}/shape2.err"
  if [[ ${shape_rc} -eq 2 ]] &&
    [[ $(<"${key_work}/shape2.err") =~ ^\[[^]]*\]\ ERROR\ (.*)$ ]] &&
    [[ ${BASH_REMATCH[1]} == "${key_work}/shape.cats.yml: the category map holds several YAML documents; it must hold one" ]] &&
    cmp --silent -- "${key_work}/shape.md" "${key_work}/shape.md.orig"; then
    pass 'a category map of two documents exits 2 and leaves the doc alone'
  else
    fail "category map of two documents: exit ${shape_rc}, want 2"
    cat -- "${key_work}/shape2.err" >&2
  fi
  rm --recursive --force -- "${key_work}"

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '%d failure(s)\n' "${failures}" >&2
    exit 1
  fi
  printf 'all passed\n'
}

main "$@"
