#!/usr/bin/env bash
# @subject scripts/*.sh
# tests/repo-root-guard.test.sh — proves every script that resolves the
# repository root exits 2 when started outside a git work tree, naming the
# cause, rather than with git's own status.
#
# Each of these scripts documents exit 2 as "could not run". A bare
# `x="$(git rev-parse --show-toplevel)"` under `set -e` ends the script
# with git's 128 instead, which no caller reads as anything; a fallback to
# `.` or `$PWD` reads the wrong tree and reports a missing input or a
# clean scan. Each row runs one script from an empty directory that git
# cannot resolve to a repository (`GIT_CEILING_DIRECTORIES` stops the
# search at it), and requires exit 2 with the diagnostic
# `scripts/lib/repo.sh` prints, which leads with the script's own name.
#
# Rows run with read-only arguments only (`--check` for the generators).
# A tripwire `gh`, `curl`, `docker` and `nix` sits first on PATH, so a
# script that got past its root lookup cannot reach the network or a
# container; any call is logged and fails the run.
#
# Two rows prove the other half: a root override still works outside a
# work tree for the scripts whose override replaces the repository root.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"

failures=0
rc=0
work="$(mktemp --directory)"
trap 'rm --recursive --force -- "${work}"' EXIT

readonly TRIPWIRE_DIR="${work}/tripwire"
readonly TRIPWIRE_LOG="${work}/tripwire.log"
mkdir --parents -- "${TRIPWIRE_DIR}"
: >"${TRIPWIRE_LOG}"
for tool in gh curl docker nix; do
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %q "$*" >>%q\nexit 97\n' \
    "${tool}" "${TRIPWIRE_LOG}" >"${TRIPWIRE_DIR}/${tool}"
  chmod +x -- "${TRIPWIRE_DIR}/${tool}"
done

function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# One row per script that resolves the repository root:
#   <script basename>|<arguments, comma-separated>
readonly -a ROWS=(
  'bump-linpeas.sh|'
  'check-actionlint-pyflakes-active.sh|'
  'check-actionlint-shellcheck-active.sh|'
  'check-bump-script-integrity.sh|'
  'check-changelog-fresh.sh|'
  'check-changelog-links.sh|'
  'check-cliff-tag-pattern.sh|'
  'check-cron-table.sh|'
  'check-doc-anchors.sh|'
  'check-doc-cron-restatement.sh|'
  'check-ephemeral-refs.sh|'
  'check-freshness-hook-watches-modules.sh|'
  'check-gh-attestation-repo.sh|'
  'check-jsonschema.sh|'
  'check-lib-source-tool-free.sh|'
  'check-lock-derived-docs.sh|'
  'check-notify-arms.sh|'
  'check-orphan-invariants.sh|'
  'check-pin-diff-isolated.sh|'
  'check-pre-commit-hooks-sha-parity.sh|'
  'check-prose-ci-names.sh|'
  'check-ratchet-pin-audit.sh|'
  'check-renovate-config-validator.sh|'
  'check-renovate-invariants.sh|'
  'check-renovate-markers-matched.sh|'
  'check-required-check-counts.sh|'
  'check-scripts-reference-roundtrip.sh|'
  'check-test-reachable.sh|'
  'check-verify-reason-ladder.sh|'
  'docs-audit-pressure.sh|'
  'gen-dashboard-data.sh|'
  'octoscan-scan.sh|'
  'refresh-ci-dag.sh|--check'
  'refresh-ci-summary.sh|--check'
  'refresh-enforcement-matrix.sh|--check'
  'refresh-ephemeral-refs-gap.sh|--check'
  'refresh-flake-show.sh|--check'
  'refresh-just-recipes.sh|--check'
  'refresh-pin-parity.sh|--check'
  'refresh-precommit-table.sh|--check'
  'refresh-scripts-reference.sh|--check'
  'refresh-test-harnesses.sh|--check'
  'refresh-treefmt-config.sh|--check'
)

if ((${#ROWS[@]} == 0)); then
  printf 'repo-root-guard: the row table is empty — nothing was run\n' >&2
  exit 2
fi

# @description Run one script from a fresh empty directory outside any work
# tree, with the tripwire first on PATH, and record the outcome with the
# cross-scenario discrimination gate. Sets `rc` in the calling scope rather
# than returning through a command substitution, whose subshell would
# discard the gate's pool state.
# @arg $1 scenario name  @arg $2 script basename  @arg $3 asserted substring
# @arg $4 comma-separated arguments  @arg $@ VAR=value environment entries
function run_outside() {
  local -r name="$1" script="$2" expect="$3" args_csv="$4"
  shift 4
  local -r cwd="${work}/cwd/${name}"
  local -r out="${work}/${name}.out"
  local -r err="${work}/${name}.err"
  local -r outcome="${work}/${name}.outcome"
  local -a args=()
  if [[ -n ${args_csv} ]]; then
    IFS=',' read -r -a args <<<"${args_csv}"
  fi
  mkdir --parents -- "${cwd}"
  rc=0
  (
    cd -- "${cwd}"
    env "$@" GIT_CEILING_DIRECTORIES="${work}/cwd" \
      PATH="${TRIPWIRE_DIR}:${PATH}" \
      bash "${REPO_ROOT}/scripts/${script}" "${args[@]}" \
      </dev/null >"${out}" 2>"${err}"
  ) || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${outcome}"
  harness_assert_record "${name}" "${expect}" "${outcome}" "${out}" "${err}"
}

row=''
for row in "${ROWS[@]}"; do
  IFS='|' read -r row_script row_args <<<"${row}"
  name="${row_script%.sh}"
  expect_line="${row_script}: cannot resolve the git work tree"
  run_outside "${name}" "${row_script}" "${expect_line}" "${row_args}"
  if [[ ${rc} -eq 2 ]] &&
    grep --fixed-strings --quiet -- "${expect_line}" "${work}/${name}.err"; then
    pass "${name}: outside a work tree is a could-not-run, exit 2"
  else
    fail "${name}: expected exit 2 naming the missing work tree, got exit ${rc}"
    cat -- "${work}/${name}.out" "${work}/${name}.err" >&2
  fi
done

# Every script that calls the helper must have a row, or a new caller's
# guard would go unexercised. The helper's own file is not a caller.
shopt -s nullglob globstar
callers=0
for f in "${REPO_ROOT}"/scripts/**/*.sh; do
  rel="${f#"${REPO_ROOT}/scripts/"}"
  [[ ${rel} == lib/repo.sh ]] && continue
  grep --quiet --extended-regexp -- '(^|[^[:alnum:]_])repo_toplevel([^[:alnum:]_]|$)' "${f}" || continue
  callers=$((callers + 1))
  found=0
  for row in "${ROWS[@]}"; do
    [[ ${row%%|*} == "${rel}" ]] && found=1 && break
  done
  if ((found == 0)); then
    fail "row-table: scripts/${rel} calls repo_toplevel but has no row"
  fi
done
shopt -u nullglob globstar
pass "row-table: ${callers} helper caller(s) checked against ${#ROWS[@]} row(s)"

# A root override replaces the repository root, so these runs need no work
# tree at all and must still pass from outside one.
mkdir --parents -- "${work}/anchor-root"
run_outside 'doc-anchors-root-override' 'check-doc-anchors.sh' \
  'check-doc-anchors: ok' '' \
  "DOC_ANCHOR_ROOT_OVERRIDE=${work}/anchor-root" 'LINT_ALLOW_EMPTY_SCAN=1'
if [[ ${rc} -eq 0 ]]; then
  pass 'doc-anchors-root-override: a root override works outside a work tree, exit 0'
else
  fail "doc-anchors-root-override: expected exit 0, got exit ${rc}"
  cat -- "${work}/doc-anchors-root-override.out" "${work}/doc-anchors-root-override.err" >&2
fi

mkdir --parents -- "${work}/ephemeral-root"
printf 'A plain sentence.\n' >"${work}/ephemeral-root/probe.md"
run_outside 'ephemeral-refs-root-override' 'check-ephemeral-refs.sh' \
  'ephemeral-refs: scanned 1 markdown' '' \
  "EPHEMERAL_REFS_ROOT_OVERRIDE=${work}/ephemeral-root" \
  'EPHEMERAL_REFS_SOURCES_OVERRIDE=probe.md'
if [[ ${rc} -eq 0 ]]; then
  pass 'ephemeral-refs-root-override: a root override works outside a work tree, exit 0'
else
  fail "ephemeral-refs-root-override: expected exit 0, got exit ${rc}"
  cat -- "${work}/ephemeral-refs-root-override.out" "${work}/ephemeral-refs-root-override.err" >&2
fi

if [[ -s ${TRIPWIRE_LOG} ]]; then
  fail 'tripwire: a script reached a network or container tool:'
  cat -- "${TRIPWIRE_LOG}" >&2
fi

printf '\nrepo-root-guard: %d script(s) run from outside a work tree\n' \
  "${#ROWS[@]}"

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -gt 0 ]]; then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
