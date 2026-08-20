#!/usr/bin/env bash
# scripts/run-harness-group.sh
#
# @description Run every setup-tax failure-mode harness in one devShell,
# printing a per-harness pass/fail summary table to stdout and
# $GITHUB_STEP_SUMMARY. Runs all harnesses even if one fails; exits 1
# if any failed.

# Harness details: ratchet-pin-audit runs its test then its live enforce
# script (safe on PR). allowed-actions-api and settings-posture need
# admin-scoped App tokens and run schedule-only in their own drift-check
# workflows, so here they run test-only (no enforce script). bump-linpeas
# downloads a release asset and rewrites linpeas-pin.json on its live
# path, so it also runs test-only here — its own bump runs from
# release-on-bump.yml, never from this shared job.

set -Eeuo pipefail
IFS=$'\n\t'

readonly TESTS_DIR="${TESTS_DIR_OVERRIDE:-tests}"
readonly SCRIPTS_DIR="${SCRIPTS_DIR_OVERRIDE:-scripts}"

# name | test-harness (under TESTS_DIR) | enforce-script (under
# SCRIPTS_DIR; empty = test-only). Pipe-delimited; no field contains a
# pipe or whitespace.
readonly -a HARNESSES=(
  'ratchet-pin-audit|check-ratchet-pin-audit.test.sh|check-ratchet-pin-audit.sh'
  'allowed-actions-api|check-allowed-actions-api.test.sh|'
  'settings-posture|check-settings-posture.test.sh|'
  'bump-linpeas|bump-linpeas.test.sh|'
  'backfill-image-mode|classify-backfill-image-mode.test.sh|'
  'renovate-flake-input|classify-renovate-flake-input.test.sh|'
  'lib-log|lib-log.test.sh|'
  'lib-enumerate|lib-enumerate.test.sh|'
  'lib-temp|lib-temp.test.sh|'
  'lib-awk-path|lib-awk-path.test.sh|'
  'lib-payload|lib-payload.test.sh|'
  'lib-generates|lib-generates.test.sh|'
  'glob-scan-breadth|glob-scan-breadth.test.sh|'
  'harness-assert|lib-harness-assert.test.sh|'
  'harness-assert-wired|_harness_assert_wired.test.sh|'
  'harness-assert-wired-spec|harness-assert-wired-spec.test.sh|'
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
  'cron-table|check-cron-table.test.sh|'
  'patch-tag-pins|check-patch-tag-pins.test.sh|'
  'run-block-pyflakes-required|check-run-block-pyflakes-required.test.sh|'
  'scorecard-threshold|check-scorecard-threshold.test.sh|'
  'compare-repro|compare-repro.test.sh|'
  'docs-audit-pressure|docs-audit-pressure.test.sh|'
  'inventory-action-pin-tags|inventory-action-pin-tags.test.sh|'
  'octoscan-scan|octoscan-scan.test.sh|'
  'run-doc-freshness|run-doc-freshness.test.sh|'
  'run-harness-group|run-harness-group.test.sh|'
  'run-lint-group|run-lint-group.test.sh|'
  'linpeas-pin-assert|linpeas-pin-assert.test.sh|'
)

function main() {
  local failed=0 passed=0
  local -a rows=()
  local entry name test_rel enforce_rel start end secs status rc stage
  for entry in "${HARNESSES[@]}"; do
    IFS='|' read -r name test_rel enforce_rel <<<"${entry}"
    rc=0
    stage=''
    start="$(date +%s)"
    if [[ ! -f "${TESTS_DIR}/${test_rel}" ]]; then
      printf '::error::missing test harness: %s/%s\n' "${TESTS_DIR}" "${test_rel}" >&2
      rc=1
      stage='missing'
    else
      bash "${TESTS_DIR}/${test_rel}" || rc=$?
      if [[ ${rc} -ne 0 ]]; then
        stage='test'
      elif [[ -n ${enforce_rel} ]]; then
        bash "${SCRIPTS_DIR}/${enforce_rel}" || rc=$?
        [[ ${rc} -eq 0 ]] || stage='enforce'
      fi
    fi
    end="$(date +%s)"
    secs=$((end - start))
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
