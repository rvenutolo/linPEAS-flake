#!/usr/bin/env bash
# @subject scripts/*.sh
# tests/glob-scan-breadth.test.sh — proves every operator-overridable glob
# scan root in scripts/ asserts its own breadth.
#
# A lint whose scan set comes from a glob under `nullglob` reads an empty
# root the same way it reads a clean one: the pattern expands to nothing,
# the loop body never runs, nothing is found and the script exits 0. That
# verdict is indistinguishable from "every file passed", so a mistyped
# override, a moved directory, or a checkout that never materialized the
# tree is scored as compliance. Each row below points one script's scan
# root at an empty directory and requires a non-zero exit carrying the
# empty-scan diagnostic, so the class cannot regrow one script at a time.
#
# A row whose script has two scan roots behind two different override
# variables appears once per root, with the other root pointed at the
# real tree so the run reaches the loop under test.
#
# The table is held complete against the tree: every top-level script that
# fills a scan set with `glob_into` and reads an `*_OVERRIDE` variable must
# have a row or an `EXEMPT` entry, and every row and entry must name such a
# script. A new overridable lint that joins neither list fails this harness
# rather than joining the class unseen.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "${REPO_ROOT}/scripts/lib/enumerate.sh"

cd "${REPO_ROOT}"
unset LINT_ALLOW_EMPTY_SCAN

failures=0
work="$(mktemp --directory)"
trap 'rm --recursive --force -- "${work}"' EXIT

readonly EMPTY="${work}/empty-root"
mkdir --parents -- "${EMPTY}"

# A root whose nix-module scan is satisfied and whose shell-script scan is
# not. The two hook-manifest checks assert their nix-module breadth before
# they reach the shell-script glob, so pointing them at a wholly empty
# root would stop them at the earlier assertion and leave the glob under
# test unexercised — a row passing on evidence its subject never produced.
readonly NIX_ROOT="${work}/nix-root"
mkdir --parents -- "${NIX_ROOT}/nix/hooks" "${NIX_ROOT}/scripts"
printf '{\n  probe = {\n    files = "^probe$";\n  };\n}\n' \
  >"${NIX_ROOT}/nix/hooks/probe.nix"

# A root whose freshness hooks name flake.lock as a trigger and whose
# workflow directory is absent. check-lock-derived-docs refuses a root with
# no lock-triggered hook before it reaches the workflow glob.
readonly LOCK_ROOT="${work}/lock-root"
mkdir --parents -- "${LOCK_ROOT}/nix/hooks"
printf '{\n  probe = {\n    files = "^flake\\\\.lock$";\n    entry = "scripts/refresh-probe.sh";\n  };\n}\n' \
  >"${LOCK_ROOT}/nix/hooks/freshness.nix"

# A root holding the real notify composite and an empty workflow directory.
# check-notify-arms pins the composite's text by hash and checks it before
# the workflow glob, so the fixture copies it rather than writing a stand-in.
readonly ARMS_ROOT="${work}/arms-root"
readonly COMPOSITE_REL='.github/actions/notify-workflow-result/action.yml'
mkdir --parents -- "${ARMS_ROOT}/.github/workflows" "${ARMS_ROOT}/${COMPOSITE_REL%/*}"
cp -- "${REPO_ROOT}/${COMPOSITE_REL}" "${ARMS_ROOT}/${COMPOSITE_REL}"

function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# One row per overridable scan root:
#   <row name>|<script basename>|<scan-set label>|<VAR=value[,VAR=value...]>
# The label is the text the script hands `glob_into`, and the assertion is
# built from the script name plus that label, so each row asserts the
# diagnostic only its own scan root can print.
readonly -a ROWS=(
  "auto-merge-decline-gate|check-auto-merge-decline-gate.sh|workflow YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY}"
  "checkout-persist-credentials|check-checkout-persist-credentials.sh|workflow YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY}"
  "ci-job-in-summary|check-ci-job-in-summary.sh|workflow YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY}"
  "cron-table|check-cron-table.sh|workflow YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY}"
  "dockerhub-token-scope-split|check-dockerhub-token-scope-split.sh|workflow YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY}"
  "doc-cron-restatement|check-doc-cron-restatement.sh|workflow YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY}"
  "egress-allowlist|check-egress-allowlist.sh|workflow YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY}"
  "exit-contract-documented|check-exit-contract-documented.sh|scripts|SCRIPTS_DIR_OVERRIDE=${EMPTY}"
  "fork-guard-release|check-fork-guard-release.sh|workflow YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY}"
  "freshness-hook-scripts|check-freshness-hook-watches-modules.sh|repo shell scripts|ROOT_OVERRIDE=${NIX_ROOT}"
  "gh-api-version-header|check-gh-api-version-header.sh|repo shell scripts|SCRIPTS_DIR_OVERRIDE=${EMPTY}"
  "guard-exit-code|check-guard-exit-code.sh|repo shell scripts|SCRIPTS_DIR_OVERRIDE=${EMPTY}"
  "harden-runner-block|check-harden-runner-block.sh|workflow YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY}"
  "harden-runner-first|check-harden-runner-first.sh|workflow YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY}"
  "harness-assert-wired|check-harness-assert-wired.sh|harness scan root|TESTS_DIR_OVERRIDE=${EMPTY}"
  "harness-preamble|check-harness-preamble.sh|test harnesses|TESTS_DIR_OVERRIDE=${EMPTY}"
  "job-timeout-minutes|check-job-timeout-minutes.sh|workflow YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY}"
  "lib-source-tool-free|check-lib-source-tool-free.sh|shell scripts under ${EMPTY}|SCRIPTS_DIR_OVERRIDE=${EMPTY}"
  "lock-derived-docs|check-lock-derived-docs.sh|.github/workflows YAML|ROOT_OVERRIDE=${LOCK_ROOT}"
  "manifest-hook-scripts|check-manifest-hook-watches-nix.sh|repo shell scripts|SCRIPTS_DIR_OVERRIDE=${NIX_ROOT}/scripts,HOOKS_DIR_OVERRIDE=${NIX_ROOT}/nix/hooks"
  "manifest-hook-modules|check-manifest-hook-watches-nix.sh|hook modules|SCRIPTS_DIR_OVERRIDE=${REPO_ROOT}/scripts,HOOKS_DIR_OVERRIDE=${EMPTY}"
  "min-permissions|check-min-permissions.sh|workflow YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY}"
  "no-opaque-procsub|check-no-opaque-procsub.sh|repo shell scripts|SCRIPTS_DIR_OVERRIDE=${EMPTY}"
  "no-pipe-into-grep-quiet|check-no-pipe-into-grep-quiet.sh|shell, workflow and composite-action files|SCAN_ROOT_OVERRIDE=${EMPTY}"
  "notify-arms|check-notify-arms.sh|workflow YAML|SCAN_ROOT_OVERRIDE=${ARMS_ROOT}"
  "notify-label-descriptions|check-notify-label-descriptions.sh|workflow YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY}"
  "payload-shape-scenario|check-payload-shape-scenario.sh|shell scripts under ${EMPTY}|SCRIPTS_DIR_OVERRIDE=${EMPTY},TESTS_DIR_OVERRIDE=${EMPTY}"
  "payload-source-helper|check-payload-source-helper.sh|shell files under ${EMPTY}, ${EMPTY}/lib and ${EMPTY}|SCRIPTS_DIR_OVERRIDE=${EMPTY},TESTS_DIR_OVERRIDE=${EMPTY}"
  "permission-scopes|check-permission-scopes.sh|workflow YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY}"
  # The base side is pinned to a directory rather than left on its default
  # git ref: resolving that ref is an earlier could-not-run guard, and a
  # checkout that never fetched the base branch stops this script there,
  # before the head scan this row exists to exercise.
  "pin-digest-provenance|check-pin-digest-provenance.sh|pin-scanned YAML|BASE_DIR_OVERRIDE=${REPO_ROOT},HEAD_DIR_OVERRIDE=${EMPTY}"
  "pr-workflows-no-secrets|check-pr-workflows-no-secrets.sh|workflow YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY}"
  "prose-ci-names|check-prose-ci-names.sh|workflow YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY}"
  "pull-request-target-absent|check-pull-request-target-absent.sh|workflow YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY}"
  "regex-range-ascii|check-regex-range-ascii.sh|scripts, script libraries and harnesses|SCRIPTS_DIR_OVERRIDE=${EMPTY},TESTS_DIR_OVERRIDE=${EMPTY}"
  "run-block-strict|check-run-block-strict.sh|workflow and composite-action files|WORKFLOWS_DIR_OVERRIDE=${EMPTY},ACTIONS_DIR_OVERRIDE=${EMPTY}"
  "script-has-test-scripts|check-script-has-test.sh|check scripts|SCRIPTS_DIR_OVERRIDE=${EMPTY},TESTS_DIR_OVERRIDE=${REPO_ROOT}/tests"
  "script-has-test-tests|check-script-has-test.sh|check-script test harnesses|SCRIPTS_DIR_OVERRIDE=${REPO_ROOT}/scripts,TESTS_DIR_OVERRIDE=${EMPTY}"
  "script-shebang-pipefail|check-script-shebang-pipefail.sh|repo shell scripts|SCRIPTS_DIR_OVERRIDE=${EMPTY}"
  "scripts-reference-roundtrip|check-scripts-reference-roundtrip.sh|scripts directory|SCRIPTS_DIR_OVERRIDE=${EMPTY}"
  "setup-nix-required|check-setup-nix-required.sh|workflow YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY}"
  "size-label-ignores|check-size-label-ignores.sh|shell scripts under ${EMPTY}|SCRIPTS_DIR_OVERRIDE=${EMPTY}"
  "test-reachable|check-test-reachable.sh|doc-freshness harnesses|TESTS_DIR_OVERRIDE=${EMPTY}"
  "tool-guarded|check-tool-guarded.sh|scripts|SCRIPTS_DIR_OVERRIDE=${EMPTY}"
  "upload-artifact-strict|check-upload-artifact-strict.sh|workflow YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY}"
  "uses-sha-pinned|check-uses-sha-pinned.sh|workflow and composite-action YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY}"
  "workflow-ascii-space|check-workflow-ascii-space.sh|workflow and composite-action YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY},ACTIONS_DIR_OVERRIDE=${EMPTY}"
  "workflow-concurrency|check-workflow-concurrency.sh|workflow YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY}"
  "workflow-on-branches|check-workflow-on-branches.sh|workflow YAML|WORKFLOWS_DIR_OVERRIDE=${EMPTY}"
  "doc-freshness-runner|run-doc-freshness.sh|doc-freshness harnesses|TESTS_DIR_OVERRIDE=${EMPTY}"
  "refresh-scripts-reference|refresh-scripts-reference.sh|scripts directory|SCRIPTS_DIR_OVERRIDE=${EMPTY}"
  # The page override keeps a run that got past the glob from rewriting
  # the tracked page.
  "refresh-test-harnesses|refresh-test-harnesses.sh|test harnesses|TESTS_DIR_OVERRIDE=${EMPTY},DOC_OVERRIDE=${work}/test-harnesses.md"
)

# A table that silently emptied would run no rows and report clean, which
# is the same defect the rows themselves exist to catch. Score the table's
# own breadth before scoring anything it holds.
if ((${#ROWS[@]} == 0)); then
  printf 'glob-scan-breadth: the row table is empty — nothing was scanned\n' >&2
  exit 2
fi

# Scripts that call `glob_into` and read an `*_OVERRIDE` variable, but
# whose globs scan no root an override can point elsewhere:
#   <script basename>|<why no row applies>
readonly -a EXEMPT=(
  "run-harness-group.sh|its only glob scans the result slots this run wrote to its own temporary directory"
  "run-lint-group.sh|its only glob scans the result slots this run wrote to its own temporary directory"
)

# @description Print the basename of every top-level script that fills a
# scan set with `glob_into` and reads an `*_OVERRIDE` variable, one per
# line. Both reads are text matches: a call is a line whose first word is
# `glob_into`, so a mention in a comment is not a call, and an override is
# a `${NAME_OVERRIDE` expansion.
function overridable_glob_scripts() {
  local -a scripts=()
  glob_into scripts 'top-level scripts' "${REPO_ROOT}/scripts/*.sh"
  local f
  for f in "${scripts[@]}"; do
    grep --quiet --extended-regexp -- '^[[:space:]]*glob_into[[:space:]]' "${f}" || continue
    LC_ALL=C grep --quiet --extended-regexp -- '\$\{[A-Z0-9_]+_OVERRIDE[:}]' "${f}" || continue
    printf '%s\n' "${f##*/}"
  done
}

declare -A listed=()
entry=''
for entry in "${ROWS[@]}"; do
  IFS='|' read -r _ entry_script _ <<<"${entry}"
  listed["${entry_script}"]='a row'
done
for entry in "${EXEMPT[@]}"; do
  entry_script="${entry%%|*}"
  if [[ -n ${listed["${entry_script}"]+set} ]]; then
    fail "completeness: ${entry_script} has both a row and an EXEMPT entry"
  fi
  listed["${entry_script}"]='an EXEMPT entry'
done

failures_before_completeness=${failures}
declare -A qualifying=()
overridable="$(overridable_glob_scripts)"
while IFS= read -r entry_script; do
  [[ -n ${entry_script} ]] || continue
  qualifying["${entry_script}"]=1
  if [[ -z ${listed["${entry_script}"]+set} ]]; then
    fail "completeness: ${entry_script} fills a scan set with glob_into behind an override, but has neither a row nor an EXEMPT entry"
  fi
done <<<"${overridable}"
if ((${#qualifying[@]} == 0)); then
  printf 'glob-scan-breadth: no script under scripts/ calls glob_into behind an override — the matcher broke\n' >&2
  exit 2
fi
for entry_script in "${!listed[@]}"; do
  if [[ -z ${qualifying["${entry_script}"]+set} ]]; then
    fail "completeness: ${entry_script} has ${listed["${entry_script}"]} but no longer calls glob_into behind an override"
  fi
done
((failures > failures_before_completeness)) ||
  pass "completeness: ${#qualifying[@]} overridable glob script(s), each with a row or an EXEMPT entry"

# @description Run one row's script with its overrides applied and its
# scan root pointed at an empty directory, then record the outcome with
# the cross-scenario discrimination gate. Sets `rc` in the calling scope
# rather than returning through a command substitution: a substitution
# forks a subshell, and the gate's pool state lives in globals a
# subshell's exit would discard.
# @arg $1 row name  @arg $2 script basename  @arg $3 asserted substring
# @arg $4 comma-separated VAR=value overrides
function run_row() {
  local -r name="$1" script="$2" expect="$3" envs="$4"
  local -r out="${work}/${name}.out"
  local -r err="${work}/${name}.err"
  local -r outcome="${work}/${name}.outcome"
  local -a env_args=()
  IFS=',' read -r -a env_args <<<"${envs}"
  rc=0
  env "${env_args[@]}" bash "${REPO_ROOT}/scripts/${script}" \
    >"${out}" 2>"${err}" || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${outcome}"
  harness_assert_record "${name}" "${expect}" "${outcome}" "${out}" "${err}"
}

row=''
for row in "${ROWS[@]}"; do
  IFS='|' read -r row_name row_script row_label row_envs <<<"${row}"
  # The diagnostic names the script and the scan set, so the pair is what
  # separates one row's evidence from every other row's.
  expect_line="${row_script}: matched 0 files via ${row_label}"
  run_row "${row_name}" "${row_script}" "${expect_line}" "${row_envs}"
  if [[ ${rc} -ne 0 ]] &&
    grep --fixed-strings --quiet -- "${expect_line}" "${work}/${row_name}.err"; then
    pass "${row_name}: an empty ${row_label} root is a could-not-run, exit ${rc}"
  else
    fail "${row_name}: expected a non-zero exit naming an empty ${row_label} scan set, got exit ${rc}"
    cat -- "${work}/${row_name}.out" "${work}/${row_name}.err" >&2
  fi
done

printf '\nglob-scan-breadth: %d scan root(s) held to the breadth assertion\n' \
  "${#ROWS[@]}"

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -gt 0 ]]; then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
