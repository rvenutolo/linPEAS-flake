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
  local stderr_file out_file actual_exit=0
  stderr_file="$(mktemp)"
  out_file="$(mktemp)"
  INVARIANT_INDEX_OVERRIDE="${FIXTURES}/${fixture}" \
    MATRIX_OUTPUT_OVERRIDE="${out_file}" \
    "${SCRIPT}" >/dev/null 2>"${stderr_file}" || actual_exit=$?
  harness_assert_record "${name}" "${expected_stderr}" "${stderr_file}"
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
  rm --force -- "${stderr_file}" "${out_file}"
}

function main() {
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
  local cx_scripts cx_out cx_err cx_rc=0
  cx_scripts="$(mktemp --directory)"
  cx_out="$(mktemp)"
  cx_err="$(mktemp)"
  PRECOMMIT_HOOK_NAMES_OVERRIDE='shellcheck' \
    INVARIANT_INDEX_OVERRIDE="${FIXTURES}/exempt-coupling/index.md" \
    CI_YML_OVERRIDE="${FIXTURES}/exempt-coupling/ci.yml" \
    SCRIPTS_DIR_OVERRIDE="${cx_scripts}" \
    MATRIX_OUTPUT_OVERRIDE="${cx_out}" \
    "${SCRIPT}" >/dev/null 2>"${cx_err}" || cx_rc=$?
  harness_assert_record 'unexempted auxiliary ci job is an orphan' \
    'orphan ci job: aux-sandbox' "${cx_err}"
  if [[ ${cx_rc} -eq 2 ]] &&
    grep --fixed-strings --quiet -- 'orphan ci job: aux-sandbox' "${cx_err}"; then
    pass 'unexempted auxiliary ci job is reported as an orphan'
  else
    fail "exempt-coupling baseline: want exit 2 naming aux-sandbox, got exit ${cx_rc}"
    cat -- "${cx_err}" >&2
  fi

  cx_rc=0
  EXEMPT_OVERRIDE='aux-sandbox' \
    PRECOMMIT_HOOK_NAMES_OVERRIDE='shellcheck' \
    INVARIANT_INDEX_OVERRIDE="${FIXTURES}/exempt-coupling/index.md" \
    CI_YML_OVERRIDE="${FIXTURES}/exempt-coupling/ci.yml" \
    SCRIPTS_DIR_OVERRIDE="${cx_scripts}" \
    MATRIX_OUTPUT_OVERRIDE="${cx_out}" \
    "${SCRIPT}" >/dev/null 2>"${cx_err}" || cx_rc=$?
  harness_assert_record 'ci-job EXEMPT list clears the orphan job' \
    '' "${cx_err}"
  if [[ ${cx_rc} -eq 0 ]]; then
    pass 'ci-job EXEMPT list from the sibling clears the orphan job'
  else
    fail "exempt-coupling: EXEMPT entry aux-sandbox did not reach the orphan-job check (exit ${cx_rc})"
    cat -- "${cx_err}" >&2
  fi
  rm --recursive --force -- "${cx_scripts}"
  rm --force -- "${cx_out}" "${cx_err}"

  # Assertion 8: an unreadable EXEMPT source aborts instead of standing in
  # for an empty list. A stub sibling that rejects --print-exempt is the
  # shape a renamed or dropped mode takes at the call site.
  local gg_dir gg_scripts gg_out gg_err gg_rc=0
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
  PRECOMMIT_HOOK_NAMES_OVERRIDE='shellcheck' \
    INVARIANT_INDEX_OVERRIDE="${FIXTURES}/exempt-coupling/index.md" \
    CI_YML_OVERRIDE="${FIXTURES}/exempt-coupling/ci.yml" \
    SCRIPTS_DIR_OVERRIDE="${gg_scripts}" \
    MATRIX_OUTPUT_OVERRIDE="${gg_out}" \
    EXEMPT_SOURCE_OVERRIDE="${gg_dir}/exempt-source-stub" \
    "${SCRIPT}" >/dev/null 2>"${gg_err}" || gg_rc=$?
  harness_assert_record 'unreadable EXEMPT source aborts' \
    '--print-exempt failed' "${gg_err}"
  if [[ ${gg_rc} -eq 2 ]] &&
    grep --fixed-strings --quiet -- '--print-exempt failed' "${gg_err}"; then
    pass 'unreadable EXEMPT source aborts instead of reading as empty'
  else
    fail "guard-the-guard: want exit 2 naming --print-exempt, got exit ${gg_rc}"
    cat -- "${gg_err}" >&2
  fi
  rm --recursive --force -- "${gg_dir}" "${gg_scripts}"
  rm --force -- "${gg_out}" "${gg_err}"

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

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '%d failure(s)\n' "${failures}" >&2
    exit 1
  fi
  printf 'all passed\n'
}

main "$@"
