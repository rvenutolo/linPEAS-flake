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

# The four reachability mechanisms, in the order the summary reports them.
# Each label is the runner an operator would go read: a harness reached only
# by one of these is only as reliable as that runner's own wiring, so the
# clean path reports the tally rather than a bare "all reachable".
readonly MECH_HARNESS_GROUP='run-harness-group.sh HARNESSES array'
readonly MECH_REFRESH_GLOB='run-doc-freshness.sh refresh-* glob'
readonly MECH_LINT_GROUPS='run-lint-group.sh lint-groups member'
readonly MECH_WORKFLOW='direct workflow invocation'
readonly -a MECHANISMS=(
  "${MECH_HARNESS_GROUP}"
  "${MECH_REFRESH_GLOB}"
  "${MECH_LINT_GROUPS}"
  "${MECH_WORKFLOW}"
)

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

# @description Emit, one per line, `<mechanism>|<harness basename>` for every
# harness the runners reach. The mechanism field is what lets the clean path
# report which runner reaches each harness; the membership test below reads
# only the name field. A harness reached by two mechanisms appears twice, once
# under each. The union may include names with no on-disk file (e.g. a
# lint-group member with no test); that is harmless — only existing harnesses
# are checked against this set.
function reachable_set() {
  # Every enumeration below is captured before it is read. A process
  # substitution runs in its own subshell, so the loop it feeds only ever
  # sees its own status: a grep that could not read a runner would look
  # like a runner that reaches nothing, and every harness it wires would
  # be reported unreachable. `grep` exit 1 is a real answer here — a
  # runner may legitimately match no line — so only a higher status is a
  # could-not-run.
  local rows status

  # 1. run-harness-group.sh HARNESSES array, field 2 (the .test.sh filename).
  if [[ -f ${HARNESS_RUNNER} ]]; then
    local entry
    status=0
    rows="$(grep -E "^[[:space:]]*'[^']+\|[^']+\.test\.sh\|[^']*'" "${HARNESS_RUNNER}")" ||
      status=$?
    if ((status > 1)); then
      printf 'grep failed reading %s for harness entries\n' "${HARNESS_RUNNER}" >&2
      exit 2
    fi
    while IFS= read -r entry; do
      [[ -z ${entry} ]] && continue
      entry="${entry#*\'}"
      entry="${entry%%\'*}"
      printf '%s|%s\n' "${MECH_HARNESS_GROUP}" "$(cut -d'|' -f2 <<<"${entry}")"
    done <<<"${rows}"
  fi

  # 2. tests/refresh-*.test.sh — name-convention glob in run-doc-freshness.sh.
  local f
  for f in "${TESTS_DIR}"/refresh-*.test.sh; do
    printf '%s|%s\n' "${MECH_REFRESH_GLOB}" "$(basename -- "${f}")"
  done

  # 3. lint-groups.yml members -> check-<name>.test.sh (run by run-lint-group).
  if [[ -f ${LINT_GROUPS} ]]; then
    local name
    status=0
    rows="$(grep -E '^[[:space:]]*-[[:space:]]+[^[:space:]]+' "${LINT_GROUPS}" |
      sed -E 's/^[[:space:]]*-[[:space:]]+//')" || status=$?
    if ((status > 1)); then
      printf 'grep failed reading %s for group members\n' "${LINT_GROUPS}" >&2
      exit 2
    fi
    while IFS= read -r name; do
      [[ -z ${name} ]] && continue
      printf '%s|check-%s.test.sh\n' "${MECH_LINT_GROUPS}" "${name}"
    done <<<"${rows}"
  fi

  # 4. Direct `tests/<x>.test.sh` invocations in any workflow file. Guard the
  # glob explicitly (nullglob makes an empty match vanish, which would leave
  # grep reading stdin).
  local -a wf_files=("${WORKFLOWS_DIR}"/*.yml)
  if ((${#wf_files[@]} > 0)); then
    local hit
    status=0
    rows="$(grep --no-filename --only-matching --extended-regexp \
      'tests/[A-Za-z0-9_.-]+\.test\.sh' "${wf_files[@]}" |
      sed 's#tests/##')" || status=$?
    if ((status > 1)); then
      printf 'grep failed reading %s for direct harness invocations\n' \
        "${WORKFLOWS_DIR}" >&2
      exit 2
    fi
    while IFS= read -r hit; do
      [[ -z ${hit} ]] && continue
      printf '%s|%s\n' "${MECH_WORKFLOW}" "${hit}"
    done <<<"${rows}"
  fi
}

# @description Print how many on-disk harnesses the given mechanism reaches.
# Names the mechanism reaches that have no harness file are not counted: the
# tally reports coverage of harnesses that exist, not entries in a manifest.
# @arg $1 mechanism label  @arg $2 the reachable set, one entry per line
function reached_count() {
  local -r mechanism="$1"
  local count=0 entry name
  while IFS= read -r entry; do
    [[ ${entry} == "${mechanism}|"* ]] || continue
    name="${entry#*|}"
    [[ -f "${TESTS_DIR}/${name}" ]] && count=$((count + 1))
  done <<<"$2"
  printf '%d' "${count}"
}

function main() {
  local reachable names
  reachable="$(reachable_set | sort --unique)"
  names="$(cut -d'|' -f2- <<<"${reachable}")"

  local failed=0 checked=0 f base
  for f in "${TESTS_DIR}"/*.test.sh; do
    base="$(basename -- "${f}")"
    is_exempt "${base}" && continue
    checked=$((checked + 1))
    if ! grep --quiet --line-regexp --fixed-strings -- "${base}" <<<"${names}"; then
      printf 'unreachable test harness (no runner executes it): %s\n' "${base}" >&2
      failed=1
    fi
  done

  if ((failed > 0)); then
    printf 'test-reachable lint: some harnesses run in no runner\n' >&2
    exit 1
  fi

  # State which runner reached what, not merely that everything was reached:
  # "all reachable" reads the same whether every harness hangs off one runner
  # or the coverage is spread across all four, and a mechanism that has
  # silently stopped matching anything is exactly the regression this lint
  # exists to catch. Counts overlap where a harness has two runners.
  printf 'test-reachable lint: %d harness(es) reachable, by runner:\n' "${checked}"
  local mechanism
  for mechanism in "${MECHANISMS[@]}"; do
    printf '  %s: %s\n' "${mechanism}" "$(reached_count "${mechanism}" "${reachable}")"
  done
  exit 0
}

main "$@"
