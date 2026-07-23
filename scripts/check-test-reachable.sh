#!/usr/bin/env bash
# scripts/check-test-reachable.sh
#
# @description Lint: every tests/*.test.sh harness is executed by some runner.
# check-script-has-test guarantees a test FILE exists for each script; it does
# not guarantee the test ever RUNS. A harness reachable by no runner is a
# coverage no-op — the regressions it would catch pass green while the pairing
# guard stays satisfied. This asserts every harness is reachable via one of
# four runners:
#   1. the HARNESSES array in scripts/run-harness-group.sh (harness-group job),
#   2. the tests/refresh-*.test.sh glob in scripts/run-doc-freshness.sh,
#   3. a .github/lint-groups.yml member -> tests/check-<name>.test.sh
#      (executed by scripts/run-lint-group.sh), or
#   4. a direct `tests/<x>.test.sh` invocation in a .github/workflows/*.yml.
#
# Overridable dirs/paths let the paired test harness point at fixtures. Exits
# 0 if every harness is reachable, 1 otherwise.
set -Eeuo pipefail
IFS=$'\n\t'
shopt -s nullglob

readonly TESTS_DIR="${TESTS_DIR_OVERRIDE:-tests}"
readonly HARNESS_RUNNER="${HARNESS_RUNNER_OVERRIDE:-scripts/run-harness-group.sh}"
readonly LINT_GROUPS="${LINT_GROUPS_OVERRIDE:-.github/lint-groups.yml}"
readonly WORKFLOWS_DIR="${WORKFLOWS_DIR_OVERRIDE:-.github/workflows}"

# Harnesses intentionally executed by no runner. Empty: every harness must be
# wired to a runner. A genuinely manual-only harness would be listed here with
# a rationale comment.
readonly -a EXEMPT=()

# @description Return 0 if the harness basename is on the EXEMPT list.
# @arg $1 harness basename
function is_exempt() {
  local -r name="$1"
  local e
  for e in "${EXEMPT[@]}"; do
    [[ ${name} == "${e}" ]] && return 0
  done
  return 1
}

# @description Emit, one per line, every harness basename the runners reach.
# The union may include names with no on-disk file (e.g. a lint-group member
# with no test); that is harmless — only existing harnesses are checked
# against this set.
function reachable_set() {
  # 1. run-harness-group.sh HARNESSES array, field 2 (the .test.sh filename).
  if [[ -f ${HARNESS_RUNNER} ]]; then
    local entry
    while IFS= read -r entry; do
      entry="${entry#*\'}"
      entry="${entry%%\'*}"
      cut -d'|' -f2 <<<"${entry}"
    done < <(grep -E "^[[:space:]]*'[^']+\|[^']+\.test\.sh\|[^']*'" "${HARNESS_RUNNER}")
  fi

  # 2. tests/refresh-*.test.sh — name-convention glob in run-doc-freshness.sh.
  local f
  for f in "${TESTS_DIR}"/refresh-*.test.sh; do
    basename -- "${f}"
  done

  # 3. lint-groups.yml members -> check-<name>.test.sh (run by run-lint-group).
  if [[ -f ${LINT_GROUPS} ]]; then
    local name
    while IFS= read -r name; do
      printf 'check-%s.test.sh\n' "${name}"
    done < <(grep -E '^[[:space:]]*-[[:space:]]+[^[:space:]]+' "${LINT_GROUPS}" |
      sed -E 's/^[[:space:]]*-[[:space:]]+//')
  fi

  # 4. Direct `tests/<x>.test.sh` invocations in any workflow file. Guard the
  # glob explicitly (nullglob makes an empty match vanish, which would leave
  # grep reading stdin) and tolerate a no-match (grep exit 1 under set -e).
  local -a wf_files=("${WORKFLOWS_DIR}"/*.yml)
  if ((${#wf_files[@]} > 0)); then
    grep --no-filename --only-matching --extended-regexp \
      'tests/[A-Za-z0-9_.-]+\.test\.sh' "${wf_files[@]}" |
      sed 's#tests/##' || true
  fi
}

function main() {
  local reachable
  reachable="$(reachable_set | sort --unique)"

  local failed=0 f base
  for f in "${TESTS_DIR}"/*.test.sh; do
    base="$(basename -- "${f}")"
    is_exempt "${base}" && continue
    if ! grep --quiet --line-regexp --fixed-strings -- "${base}" <<<"${reachable}"; then
      printf 'unreachable test harness (no runner executes it): %s\n' "${base}" >&2
      failed=1
    fi
  done

  if ((failed > 0)); then
    printf 'test-reachable lint: some harnesses run in no runner\n' >&2
    exit 1
  fi
  exit 0
}

main "$@"
