#!/usr/bin/env bash
# tests/refresh-enforcement-matrix.test.sh
#
# Round-trip + drift + failure-mode harness for
# scripts/refresh-enforcement-matrix.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/refresh-enforcement-matrix.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/refresh-enforcement-matrix"

# The reverse-direction scenarios below drive fixture indexes that name
# none of the real repo's enforcers. The live roster's enforce script is
# one of those, so without a fixture roster every such scenario would trip
# the roster-to-index half of the harness-group assertion on a fact none of
# them is about. A roster whose entries are all test-only leaves that half
# with nothing to demand while still exercising the producer contract.
# @arg $1 path to write  @arg $2... roster entries the stub prints
function write_roster_stub() {
  local -r path="$1"
  shift
  cat >"${path}" <<'STUB'
#!/usr/bin/env bash
if [[ ${1:-} != '--print-roster' ]]; then
  printf 'unknown argument: %s\n' "${1:-}" >&2
  exit 2
fi
STUB
  {
    printf 'cat <<%s\n' "'ENTRIES'"
    printf '%s\n' "$@"
    printf 'ENTRIES\n'
  } >>"${path}"
  chmod +x "${path}"
}

# Inline hook list keeps the harness independent of `nix eval` for the
# fixture scenarios. The real-index assertion deliberately omits the
# override so it exercises the live flake.
readonly FIXTURE_HOOKS=$'uses-sha-pinned\nrenovate-invariants\nharden-runner-first\nbogus\ny'

failures=0

# Guard against leaving the planted leak-test stray behind on any exit
# (including an early assertion failure). Script-scoped so the trap sees it.
readonly LEAK_STRAY="${REPO_ROOT}/.refresh-enforcement-matrix-deadbeef.md"
function cleanup_test() { rm --force -- "${LEAK_STRAY}"; }
trap cleanup_test EXIT

function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# run_scenario <name> <fixture> <expected_exit> <expected_stderr_substring>
function run_scenario() {
  local -r name="$1" fixture="$2" expected_exit="$3" expected_stderr="$4"
  local stderr_file stdout_file outcome_file out_file actual_exit=0
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"
  out_file="$(mktemp)"
  INVARIANT_INDEX_OVERRIDE="${FIXTURES}/${fixture}" \
    MATRIX_OUTPUT_OVERRIDE="${out_file}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  # The record is the whole observable outcome — exit code, stdout, stderr —
  # so a scenario that differs from a sibling only in how it ended still
  # reads as a distinct observation.
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    fail "${name}: expected exit ${expected_exit}, got ${actual_exit}"
    cat -- "${stderr_file}" >&2
  elif [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    fail "${name}: stderr missing ${expected_stderr}"
    cat -- "${stderr_file}" >&2
  else
    pass "${name} (exit ${actual_exit})"
  fi
  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}" "${out_file}"
}

function main() {
  # Test-only roster for every fixture-index scenario that leaves the
  # reverse checks on. See write_roster_stub.
  local test_only_roster
  test_only_roster="$(mktemp)"
  write_roster_stub "${test_only_roster}" 'stub-a|stub-a.test.sh|' 'stub-b|stub-b.test.sh|'

  # Assertion 1: real index → real matrix → --check is clean (round-trip).
  "${SCRIPT}" >/dev/null
  if "${SCRIPT}" --check >/dev/null 2>&1; then
    pass 'real-index --check is clean after generate'
  else
    fail 'real-index --check failed right after generate'
  fi

  # Assertion 2: typoed enforcer reference → exit 2.
  SKIP_REVERSE_CHECK=1 PRECOMMIT_HOOK_NAMES_OVERRIDE="${FIXTURE_HOOKS}" \
    run_scenario 'typoed enforcer fails' \
    'bad-typo-enforcer.md' 2 'check-does-not-exist.sh'

  # Assertion 3: missing required field → exit 2.
  SKIP_REVERSE_CHECK=1 PRECOMMIT_HOOK_NAMES_OVERRIDE="${FIXTURE_HOOKS}" \
    run_scenario 'missing enforcer field fails' \
    'bad-missing-field.md' 2 "annotation missing 'enforcer' field"

  # Assertion 4: orphan script (real check-*.sh not referenced) → exit 2.
  # Reverse check intentionally enabled here.
  ROSTER_SOURCE_OVERRIDE="${test_only_roster}" \
    PRECOMMIT_HOOK_NAMES_OVERRIDE="${FIXTURE_HOOKS}" \
    run_scenario 'orphan check-*.sh fails' \
    'bad-orphan-script.md' 2 'orphan script:'

  # Assertion 5: good fixture round-trips against pinned expected output.
  # Inject the hook-name list inline so the fixture round-trip doesn't
  # depend on the slow `nix eval` path and stays stable across flake
  # refactors.
  local out_file
  out_file="$(mktemp)"
  SKIP_REVERSE_CHECK=1 \
    PRECOMMIT_HOOK_NAMES_OVERRIDE=$'uses-sha-pinned\nrenovate-invariants\nharden-runner-first' \
    INVARIANT_INDEX_OVERRIDE="${FIXTURES}/good-index.md" \
    MATRIX_OUTPUT_OVERRIDE="${out_file}" \
    "${SCRIPT}" >/dev/null 2>&1
  if diff --unified "${FIXTURES}/expected-matrix.md" "${out_file}"; then
    pass 'good fixture matches expected matrix'
  else
    fail 'good fixture diverges from expected matrix'
  fi
  rm --force -- "${out_file}"

  # Assertion 6: an interrupted run leaks no in-repo .md temp, and the
  # EXIT-trap sweep removes any pre-existing stray. Plant a stray in the
  # repo root, run default mode, assert no .refresh-enforcement-matrix-*.md
  # remain afterward.
  : >"${LEAK_STRAY}"
  local leak_out
  leak_out="$(mktemp)"
  MATRIX_OUTPUT_OVERRIDE="${leak_out}" "${SCRIPT}" >/dev/null 2>&1 || true
  rm --force -- "${leak_out}"
  local remaining
  # enumerate-exempt: this find counts leaked temps, and zero is the
  # result the row demands — the check below passes on remaining -eq 0.
  # Routing it through the enumeration helper would make the clean tree
  # exit 2, turning the assertion's success condition into a failure.
  remaining="$(find "${REPO_ROOT}" -maxdepth 1 -type f \
    -name '.refresh-enforcement-matrix-*.md' | wc -l | tr -d '[:space:]')"
  if [[ ! -e ${LEAK_STRAY} ]] && [[ ${remaining} -eq 0 ]]; then
    pass 'leak cleanup removes stray in-repo .md temp'
  else
    fail "leak cleanup left ${remaining} stray .refresh-enforcement-matrix-*.md (planted stray exists: $([[ -e ${LEAK_STRAY} ]] && echo yes || echo no))"
  fi

  # Assertion 7: the ci-job EXEMPT list crosses from
  # scripts/check-ci-job-in-summary.sh into the orphan-job check, proven
  # with a NON-EMPTY list. A fixture ci.yml job that no invariant bullet
  # references is an orphan; naming it in the sibling's EXEMPT list clears
  # it. An exemption list that is empty on both sides cannot tell a live
  # coupling from a dead one, so the populated case is the one that pins
  # it. The fixture index uses the `-` sentinel in all three fields and
  # the scripts dir is empty, leaving the ci-job column as the only
  # orphan source.
  local cx_scripts cx_out cx_err cx_stdout cx_outcome cx_rc=0
  cx_scripts="$(mktemp --directory)"
  cx_out="$(mktemp)"
  cx_err="$(mktemp)"
  cx_stdout="$(mktemp)"
  cx_outcome="$(mktemp)"
  ROSTER_SOURCE_OVERRIDE="${test_only_roster}" \
    PRECOMMIT_HOOK_NAMES_OVERRIDE='shellcheck' \
    INVARIANT_INDEX_OVERRIDE="${FIXTURES}/exempt-coupling/index.md" \
    CI_YML_OVERRIDE="${FIXTURES}/exempt-coupling/ci.yml" \
    SCRIPTS_DIR_OVERRIDE="${cx_scripts}" \
    MATRIX_OUTPUT_OVERRIDE="${cx_out}" \
    "${SCRIPT}" >"${cx_stdout}" 2>"${cx_err}" || cx_rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${cx_rc}" >"${cx_outcome}"
  harness_assert_record 'unexempted auxiliary ci job is an orphan' \
    'orphan ci job: aux-sandbox' "${cx_outcome}" "${cx_stdout}" "${cx_err}"
  if [[ ${cx_rc} -eq 2 ]] &&
    grep --fixed-strings --quiet -- 'orphan ci job: aux-sandbox' "${cx_err}"; then
    pass 'unexempted auxiliary ci job is reported as an orphan'
  else
    fail "exempt-coupling baseline: want exit 2 naming aux-sandbox, got exit ${cx_rc}"
    cat -- "${cx_err}" >&2
  fi

  cx_rc=0
  ROSTER_SOURCE_OVERRIDE="${test_only_roster}" \
    EXEMPT_OVERRIDE='aux-sandbox' \
    PRECOMMIT_HOOK_NAMES_OVERRIDE='shellcheck' \
    INVARIANT_INDEX_OVERRIDE="${FIXTURES}/exempt-coupling/index.md" \
    CI_YML_OVERRIDE="${FIXTURES}/exempt-coupling/ci.yml" \
    SCRIPTS_DIR_OVERRIDE="${cx_scripts}" \
    MATRIX_OUTPUT_OVERRIDE="${cx_out}" \
    "${SCRIPT}" >"${cx_stdout}" 2>"${cx_err}" || cx_rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${cx_rc}" >"${cx_outcome}"
  harness_assert_record 'ci-job EXEMPT list clears the orphan job' \
    '' "${cx_outcome}" "${cx_stdout}" "${cx_err}"
  if [[ ${cx_rc} -eq 0 ]]; then
    pass 'ci-job EXEMPT list from the sibling clears the orphan job'
  else
    fail "exempt-coupling: EXEMPT entry aux-sandbox did not reach the orphan-job check (exit ${cx_rc})"
    cat -- "${cx_err}" >&2
  fi
  rm --recursive --force -- "${cx_scripts}"
  rm --force -- "${cx_out}" "${cx_err}" "${cx_stdout}" "${cx_outcome}"

  # Assertion 8: an unreadable EXEMPT source aborts instead of standing in
  # for an empty list. A stub sibling that rejects --print-exempt is the
  # shape a renamed or dropped mode takes at the call site.
  local gg_dir gg_scripts gg_out gg_err gg_stdout gg_outcome gg_rc=0
  gg_dir="$(mktemp --directory)"
  gg_scripts="$(mktemp --directory)"
  cat >"${gg_dir}/exempt-source-stub" <<'EOF'
#!/usr/bin/env bash
printf 'stub: unknown argument: %s\n' "${1:-}" >&2
exit 2
EOF
  chmod +x "${gg_dir}/exempt-source-stub"
  gg_out="$(mktemp)"
  gg_err="$(mktemp)"
  gg_stdout="$(mktemp)"
  gg_outcome="$(mktemp)"
  ROSTER_SOURCE_OVERRIDE="${test_only_roster}" \
    PRECOMMIT_HOOK_NAMES_OVERRIDE='shellcheck' \
    INVARIANT_INDEX_OVERRIDE="${FIXTURES}/exempt-coupling/index.md" \
    CI_YML_OVERRIDE="${FIXTURES}/exempt-coupling/ci.yml" \
    SCRIPTS_DIR_OVERRIDE="${gg_scripts}" \
    MATRIX_OUTPUT_OVERRIDE="${gg_out}" \
    EXEMPT_SOURCE_OVERRIDE="${gg_dir}/exempt-source-stub" \
    "${SCRIPT}" >"${gg_stdout}" 2>"${gg_err}" || gg_rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${gg_rc}" >"${gg_outcome}"
  harness_assert_record 'unreadable EXEMPT source aborts' \
    '--print-exempt failed' "${gg_outcome}" "${gg_stdout}" "${gg_err}"
  if [[ ${gg_rc} -eq 2 ]] &&
    grep --fixed-strings --quiet -- '--print-exempt failed' "${gg_err}"; then
    pass 'unreadable EXEMPT source aborts instead of reading as empty'
  else
    fail "guard-the-guard: want exit 2 naming --print-exempt, got exit ${gg_rc}"
    cat -- "${gg_err}" >&2
  fi
  rm --recursive --force -- "${gg_dir}" "${gg_scripts}"
  rm --force -- "${gg_out}" "${gg_err}" "${gg_stdout}" "${gg_outcome}"

  # Swallowed-treefmt scenario: a failing treefmt must abort the generator
  # (nonzero exit) and must NOT write the unformatted matrix into place. With
  # the `|| true` swallow the run went green while moving the unformatted
  # render into the output file. Reuses the hermetic good-index fixture path.
  local ts_out ts_bin ts_rc=0
  ts_out="$(mktemp)"
  ts_bin="$(mktemp --directory)"
  cat >"${ts_bin}/treefmt" <<'EOF'
#!/usr/bin/env bash
echo 'treefmt stub: simulated failure' >&2
exit 1
EOF
  chmod +x "${ts_bin}/treefmt"
  PATH="${ts_bin}:${PATH}" \
    SKIP_REVERSE_CHECK=1 \
    PRECOMMIT_HOOK_NAMES_OVERRIDE=$'uses-sha-pinned\nrenovate-invariants\nharden-runner-first' \
    INVARIANT_INDEX_OVERRIDE="${FIXTURES}/good-index.md" \
    MATRIX_OUTPUT_OVERRIDE="${ts_out}" \
    "${SCRIPT}" >/dev/null 2>&1 || ts_rc=$?
  rm --recursive --force -- "${ts_bin}"
  local ts_empty='no'
  [[ ! -s ${ts_out} ]] && ts_empty='yes'
  rm --force -- "${ts_out}"
  if [[ ${ts_rc} -ne 0 && ${ts_empty} == 'yes' ]]; then
    pass 'failing treefmt aborts without writing an unformatted matrix'
  else
    fail "treefmt-failure: want nonzero exit + no output written, got exit ${ts_rc}, empty=${ts_empty}"
  fi

  # A `nix` that is present and fails has evaluated nothing: exit 2, not
  # the exit 1 that --check mode reads as a document to regenerate.
  local nix_shim nix_err nix_out nix_outcome nix_rc=0
  nix_shim="$(mktemp --directory)"
  nix_err="$(mktemp)"
  nix_out="$(mktemp)"
  nix_outcome="$(mktemp)"
  printf '#!/usr/bin/env bash\nexit 1\n' >"${nix_shim}/nix"
  chmod +x -- "${nix_shim}/nix"
  PATH="${nix_shim}:${PATH}" "${SCRIPT}" --check >"${nix_out}" 2>"${nix_err}" || nix_rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${nix_rc}" >"${nix_outcome}"
  harness_assert_record 'failing nix eval is a tooling error' \
    'could not evaluate' "${nix_outcome}" "${nix_out}" "${nix_err}"
  if [[ ${nix_rc} -eq 2 ]] &&
    grep --fixed-strings --quiet -- 'could not evaluate' "${nix_err}"; then
    pass 'failing nix eval is a tooling error, not a stale document'
  else
    fail "failing nix eval: expected exit 2 + 'could not evaluate', got exit ${nix_rc}"
    sed 's/^/    /' "${nix_err}" >&2
  fi
  rm --recursive --force -- "${nix_shim}"
  rm --force -- "${nix_err}" "${nix_out}" "${nix_outcome}"

  # Harness-group assertion. `harness-group` is a real ci.yml job, so every
  # other cross-check accepts `ci: harness-group` on any entry that writes
  # it. What decides whether the job actually enforces a rule is the third
  # field of the roster in scripts/run-harness-group.sh: an entry naming an
  # enforce script has it run against the checkout, a test-only entry does
  # not. Each scenario below pairs a fixture index with a roster and
  # changes only one of the two, so the failure it produces is
  # attributable to the annotation or to the roster, never to both.
  local hg_scripts hg_roster hg_out hg_err hg_stdout hg_outcome hg_rc
  hg_scripts="$(mktemp --directory)"
  : >"${hg_scripts}/check-thing.sh"
  hg_roster="$(mktemp)"
  hg_out="$(mktemp)"
  hg_err="$(mktemp)"
  hg_stdout="$(mktemp)"
  hg_outcome="$(mktemp)"

  # Roster runs check-thing.sh and an entry annotates it: both directions
  # are satisfied, so the run reaches the render.
  hg_rc=0
  write_roster_stub "${hg_roster}" 'thing|thing.test.sh|check-thing.sh' 'other|other.test.sh|'
  ROSTER_SOURCE_OVERRIDE="${hg_roster}" \
    PRECOMMIT_HOOK_NAMES_OVERRIDE='shellcheck' \
    INVARIANT_INDEX_OVERRIDE="${FIXTURES}/harness-group/annotated-index.md" \
    CI_YML_OVERRIDE="${FIXTURES}/harness-group/ci.yml" \
    SCRIPTS_DIR_OVERRIDE="${hg_scripts}" \
    MATRIX_OUTPUT_OVERRIDE="${hg_out}" \
    EXEMPT_OVERRIDE='lint-script-hygiene' \
    "${SCRIPT}" >"${hg_stdout}" 2>"${hg_err}" || hg_rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${hg_rc}" >"${hg_outcome}"
  harness_assert_record 'roster enforces the annotated rule' \
    '' "${hg_outcome}" "${hg_stdout}" "${hg_err}"
  if [[ ${hg_rc} -eq 0 ]]; then
    pass 'annotation backed by a roster enforce field passes'
  else
    fail "harness-group: backed annotation should pass, got exit ${hg_rc}"
    cat -- "${hg_err}" >&2
  fi

  # Same index, roster demoted to test-only: the entry now claims a job
  # that enforces nothing. This is the direction that catches an annotation
  # written from the job name alone.
  hg_rc=0
  write_roster_stub "${hg_roster}" 'thing|thing.test.sh|' 'other|other.test.sh|'
  ROSTER_SOURCE_OVERRIDE="${hg_roster}" \
    PRECOMMIT_HOOK_NAMES_OVERRIDE='shellcheck' \
    INVARIANT_INDEX_OVERRIDE="${FIXTURES}/harness-group/annotated-index.md" \
    CI_YML_OVERRIDE="${FIXTURES}/harness-group/ci.yml" \
    SCRIPTS_DIR_OVERRIDE="${hg_scripts}" \
    MATRIX_OUTPUT_OVERRIDE="${hg_out}" \
    EXEMPT_OVERRIDE='lint-script-hygiene' \
    "${SCRIPT}" >"${hg_stdout}" 2>"${hg_err}" || hg_rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${hg_rc}" >"${hg_outcome}"
  harness_assert_record 'annotation claims a test-only roster entry' \
    'claims ci: harness-group' "${hg_outcome}" "${hg_stdout}" "${hg_err}"
  if [[ ${hg_rc} -eq 2 ]] &&
    grep --fixed-strings --quiet -- 'claims ci: harness-group' "${hg_err}"; then
    pass 'annotation on a test-only roster entry is rejected'
  else
    fail "harness-group: want exit 2 naming the bullet, got exit ${hg_rc}"
    cat -- "${hg_err}" >&2
  fi

  # Roster still enforces check-thing.sh, but the index attributes it to a
  # different job. The reverse direction catches an enforcer that gained a
  # live enforcement pass nothing records.
  hg_rc=0
  write_roster_stub "${hg_roster}" 'thing|thing.test.sh|check-thing.sh' 'other|other.test.sh|'
  ROSTER_SOURCE_OVERRIDE="${hg_roster}" \
    PRECOMMIT_HOOK_NAMES_OVERRIDE='shellcheck' \
    INVARIANT_INDEX_OVERRIDE="${FIXTURES}/harness-group/unannotated-index.md" \
    CI_YML_OVERRIDE="${FIXTURES}/harness-group/ci.yml" \
    SCRIPTS_DIR_OVERRIDE="${hg_scripts}" \
    MATRIX_OUTPUT_OVERRIDE="${hg_out}" \
    EXEMPT_OVERRIDE='harness-group' \
    "${SCRIPT}" >"${hg_stdout}" 2>"${hg_err}" || hg_rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${hg_rc}" >"${hg_outcome}"
  harness_assert_record 'roster enforcer is annotated for another job' \
    'but no invariant-index entry naming it says ci: harness-group' \
    "${hg_outcome}" "${hg_stdout}" "${hg_err}"
  if [[ ${hg_rc} -eq 2 ]] &&
    grep --fixed-strings --quiet -- 'check-thing.sh' "${hg_err}"; then
    pass 'roster enforcer with no harness-group annotation is rejected'
  else
    fail "harness-group reverse: want exit 2 naming check-thing.sh, got exit ${hg_rc}"
    cat -- "${hg_err}" >&2
  fi

  rm --recursive --force -- "${hg_scripts}"
  rm --force -- "${hg_roster}" "${hg_out}" "${hg_err}" "${hg_stdout}" "${hg_outcome}"

  rm --force -- "${test_only_roster}"

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '%d failure(s)\n' "${failures}" >&2
    exit 1
  fi
  printf 'all passed\n'
}

main "$@"
