#!/usr/bin/env bash
# scripts/run-harness-group.sh
#
# @description Run every setup-tax failure-mode harness in one devShell,
# printing a per-harness pass/fail summary table to stdout and
# $GITHUB_STEP_SUMMARY. Harnesses run concurrently, at most
# CHECK_WORKERS_OVERRIDE (default nproc) at a time, with each one's
# output replayed in roster order once all have finished. Runs all
# harnesses even if one fails; exits 1 if any failed.
# @option --print-roster print the HARNESSES roster, one pipe-delimited entry per line, and exit 0 without running anything

# Harness details: ratchet-pin-audit runs its test then its live enforce
# script (safe on PR). Every other entry runs test-only (no enforce
# script). bump-linpeas downloads a release asset and rewrites
# linpeas-pin.json on its live path, so it runs test-only here — its own
# bump runs from release-on-bump.yml, never from this shared job.
#
# The roster as a shared declaration — `--print-roster` writes every
# entry to stdout verbatim, one per line, and exits 0 without running a
# harness. The third field decides a fact other checks need: an entry
# naming an enforce script has that script run against the live checkout
# here, and a test-only entry does not, which is what makes
# `ci: harness-group` true or false for an invariant.
# scripts/refresh-enforcement-matrix.sh reads the roster through this
# mode so that annotation is asserted against the roster rather than
# against a regex scrape of the array. The whole roster is printed, not
# just the enforce fields, so the output is never legitimately empty and
# a caller can treat no output as a broken producer. Any other argument
# exits 2, so a renamed or dropped mode fails loud in the caller.
#
# Exit codes:
#   0 — every harness passed, or --print-roster completed.
#   1 — at least one harness failed its test or its enforce stage.
#   2 — usage error: an unknown or extra argument, a roster name written
#       twice, or a worker that left no status.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/parallel.sh
source "${_lib_dir}/lib/parallel.sh"
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"

readonly TESTS_DIR="${TESTS_DIR_OVERRIDE:-tests}"
readonly SCRIPTS_DIR="${SCRIPTS_DIR_OVERRIDE:-scripts}"
readonly ROOT_DIR="${ROOT_DIR_OVERRIDE:-.}"

# name | test-harness | enforce-script (under SCRIPTS_DIR; empty =
# test-only). Pipe-delimited; no field contains a pipe or whitespace.
# A test-harness field holding a `/` is a repo-root-relative path resolved
# under ROOT_DIR; a bare filename resolves under TESTS_DIR. The two forms
# cannot collide, since a bare filename holds no separator.
readonly -a HARNESSES=(
  'ratchet-pin-audit|check-ratchet-pin-audit.test.sh|check-ratchet-pin-audit.sh'
  'bump-linpeas|bump-linpeas.test.sh|'
  'backfill-image-mode|classify-backfill-image-mode.test.sh|'
  'renovate-flake-input|classify-renovate-flake-input.test.sh|'
  'renovate-pr-author|classify-renovate-pr-author.test.sh|'
  'flake-lock-staleness|check-flake-lock-staleness.test.sh|'
  'refresh-notify-result|classify-refresh-notify-result.test.sh|'
  'classify-ci-run|classify-ci-run.test.sh|'
  'retry-command|retry-command.test.sh|'
  'fetch-ci-run|fetch-ci-run.test.sh|'
  'ci-watchdog-coverage|ci-watchdog-coverage.test.sh|'
  'select-automated-runs|select-automated-runs.test.sh|'
  'notify-caller-permissions|notify-caller-permissions.test.sh|'
  'changelog-pr-handoff|changelog-pr-handoff.test.sh|'
  'lib-log|lib-log.test.sh|'
  'lib-enumerate|lib-enumerate.test.sh|'
  'lib-repo|lib-repo.test.sh|'
  'lib-temp|lib-temp.test.sh|'
  'lib-awk-path|lib-awk-path.test.sh|'
  'lib-payload|lib-payload.test.sh|'
  'lib-generates|lib-generates.test.sh|'
  'lib-locale-gap|lib-locale-gap.test.sh|'
  'lib-ascii-match|lib-ascii-match.test.sh|'
  'lib-secret-uses|lib-secret-uses.test.sh|'
  'lib-job-keys|lib-job-keys.test.sh|'
  'lib-md-fence|lib-md-fence.test.sh|'
  'lib-parallel|lib-parallel.test.sh|'
  'md-fence-shapes|md-fence-shapes.test.sh|'
  'glob-scan-breadth|glob-scan-breadth.test.sh|'
  'repo-root-guard|repo-root-guard.test.sh|'
  'site-no-bytecode|site-no-bytecode.test.sh|'
  'harness-no-tracked-writes|harness-no-tracked-writes.test.sh|'
  'harness-assert|lib-harness-assert.test.sh|'
  # Harnesses with no bespoke CI job, lint-group, or refresh-* glob home run
  # here test-only. Any paired enforce script runs in its own workflow or
  # pre-commit hook (e.g. octoscan-scan.sh in octoscan.yml,
  # check-scorecard-threshold.sh in scorecard-drift-check.yml), so re-running
  # it here would be redundant or need inputs this job lacks; the spec-test
  # is the piece that was otherwise executed nowhere.
  'script-docs|_script_docs.test.sh|'
  'attestation-invocations|_attestation_invocations.test.sh|'
  'apply-patch-tag-pin-rewrite|apply-patch-tag-pin-rewrite.test.sh|'
  'actionlint-shellcheck-active|check-actionlint-shellcheck-active.test.sh|'
  'actionlint-pyflakes-active|check-actionlint-pyflakes-active.test.sh|'
  'cron-table|check-cron-table.test.sh|'
  'patch-tag-pins|check-patch-tag-pins.test.sh|'
  'scorecard-threshold|check-scorecard-threshold.test.sh|'
  'compare-repro|compare-repro.test.sh|'
  'docs-audit-pressure|docs-audit-pressure.test.sh|'
  'mark-docs-audit|mark-docs-audit.test.sh|'
  'inventory-action-pin-tags|inventory-action-pin-tags.test.sh|'
  'octoscan-scan|octoscan-scan.test.sh|'
  'run-doc-freshness|run-doc-freshness.test.sh|'
  'run-harness-group|run-harness-group.test.sh|'
  'run-lint-group|run-lint-group.test.sh|'
  'linpeas-pin-assert|linpeas-pin-assert.test.sh|'
  # Tracked harnesses outside tests/. Nearly all of `.claude/` is untracked,
  # but the docs-correctness-audit and docs-audit-fix skills and the
  # seeded-defect eval are committed, and their harnesses are reachable from
  # no other runner — scripts/check-test-reachable.sh holds that. Test-only:
  # the paired scripts build a throwaway worktree, read a results manifest,
  # emit the audit's ground-truth bundle, or check a fix pass's ledger against
  # a diff, none of which is an enforcement pass this job could act on.
  'docs-audit-plant|.claude/skills/docs-correctness-audit/evals/seeded-defects/plant.test.sh|'
  'docs-audit-score|.claude/skills/docs-correctness-audit/evals/seeded-defects/score.test.sh|'
  'docs-audit-ground-truth|.claude/skills/docs-correctness-audit/scripts/collect-ground-truth.test.sh|'
  'docs-audit-fix-ledger|.claude/skills/docs-audit-fix/scripts/check-fix-ledger.test.sh|'
)

# Argument handling sits directly after the roster so the mode stays
# readable without the tests, scripts, or repo root the run path needs.
if (($# > 0)); then
  case "$1" in
  --print-roster)
    if (($# > 1)); then
      printf 'unexpected extra arguments after %s\n' "$1" >&2
      exit 2
    fi
    printf '%s\n' "${HARNESSES[@]}"
    exit 0
    ;;
  *)
    printf 'unknown argument: %s\n' "$1" >&2
    exit 2
    ;;
  esac
fi

# Runs one roster entry by name: its test harness, then its enforce
# script when the entry names one and the test passed. Invoked by
# `run_parallel`, which captures the output and status; the stage that
# failed goes to the slot so the table can name it.
# @arg $1 harness name  @arg $2 slot path
# shellcheck disable=SC2329 # invoked by name through run_parallel
function run_one() {
  local -r name="$1" slot="$2"
  local test_rel enforce_rel test_path rc=0
  IFS='|' read -r test_rel enforce_rel <<<"${ENTRY_BY_NAME[${name}]}"
  if [[ ${test_rel} == */* ]]; then
    test_path="${ROOT_DIR}/${test_rel}"
  else
    test_path="${TESTS_DIR}/${test_rel}"
  fi
  if [[ ! -f ${test_path} ]]; then
    printf '::error::missing test harness: %s\n' "${test_path}" >&2
    printf 'missing\n' >"${slot}.stage"
    return 1
  fi
  bash "${test_path}" || rc=$?
  if [[ ${rc} -ne 0 ]]; then
    printf 'test\n' >"${slot}.stage"
    return "${rc}"
  fi
  if [[ -n ${enforce_rel} ]]; then
    bash "${SCRIPTS_DIR}/${enforce_rel}" || rc=$?
    if [[ ${rc} -ne 0 ]]; then
      printf 'enforce\n' >"${slot}.stage"
      return "${rc}"
    fi
  fi
}

function main() {
  local failed=0 passed=0
  local -a rows=() names=() name_files=()
  local entry name test_rel enforce_rel secs status rc stage slot
  declare -A ENTRY_BY_NAME=()
  for entry in "${HARNESSES[@]}"; do
    IFS='|' read -r name test_rel enforce_rel <<<"${entry}"
    # Entries are looked up by name, so a name written twice would run
    # the later entry twice and the earlier one never, with the table
    # and tally showing nothing amiss.
    if [[ -v ENTRY_BY_NAME["${name}"] ]]; then
      printf 'run-harness-group: roster names %s twice\n' "${name}" >&2
      exit 2
    fi
    names+=("${name}")
    ENTRY_BY_NAME["${name}"]="${test_rel}|${enforce_rel}"
  done

  local results
  results="$(make_temp --directory)"
  # shellcheck disable=SC2064 # expanded now on purpose: the path is fixed once created
  trap "rm --recursive --force -- '${results}'" EXIT

  # A bare call, so errexit stays live inside run_one; the per-entry
  # verdict is read from the slot files below. See run_parallel.
  run_parallel run_one "${results}" "${names[@]}"

  glob_into name_files 'harness-group results' "${results}/*.name"
  for slot in "${name_files[@]}"; do
    slot="${slot%.name}"
    name="$(<"${slot}.name")"
    rc="$(<"${slot}.rc")"
    secs="$(<"${slot}.secs")"
    stage=''
    if [[ -f ${slot}.stage ]]; then
      stage="$(<"${slot}.stage")"
    fi
    # payload-read-exempt: the slot file is this runner's own buffered copy of a check's stdout and stderr, replayed verbatim into the log; it is not a payload to parse, and a missing slot is already a could-not-run from glob_into above.
    cat -- "${slot}.out"
    if [[ ${rc} -eq 0 ]]; then
      status='pass'
      passed=$((passed + 1))
    else
      # A bare FAIL leaves the reader unable to tell a harness whose spec
      # test failed from one whose live enforce script failed after a
      # passing test — different code, different fix, and the enforce stage
      # only runs at all when the test stage passed. The cell names the
      # stage that set rc so the row points at the thing to open.
      status="FAIL (${stage})"
      failed=1
    fi
    rows+=("$(printf '| %s | %s | %ds |' "${name}" "${status}" "${secs}")")
  done

  emit_table
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    {
      printf '### harness-group\n\n'
      emit_table
    } >>"${GITHUB_STEP_SUMMARY}"
  fi

  # The table alone says only what each harness did, so an all-pass run is
  # recognizable only by the absence of a FAIL row — nothing a reader (or a
  # log grep) can match on. The tally states the outcome positively, and
  # carries the failure count so that "everything passed" is one fixed
  # token rather than a number that moves whenever a harness is declared.
  # The count comes from the loop's own verdict rather than from re-reading
  # the rendered rows, so widening a status cell cannot silently change it.
  printf 'harness-group: %d/%d harnesses passed, %d failed\n' \
    "${passed}" "${#rows[@]}" "$((${#rows[@]} - passed))"

  exit "${failed}"
}

# Emits the markdown summary table from main's `rows` (dynamic scope).
function emit_table() {
  printf '| harness | result | time |\n'
  printf '| --- | --- | --- |\n'
  # shellcheck disable=SC2154
  printf '%s\n' "${rows[@]}"
}

main "$@"
