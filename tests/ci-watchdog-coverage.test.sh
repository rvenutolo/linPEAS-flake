#!/usr/bin/env bash
# tests/ci-watchdog-coverage.test.sh
# @subject .github/workflows/ci-watchdog.yml
#
# Asserts that the CI watchdog's `on.workflow_run.workflows` list is
# exactly the set of `name:` values of every other workflow under
# .github/workflows, and that the trigger fires on `completed`. A
# workflow missing from the list gets no retry minutes after it fails,
# only on the next cron tick, and nothing else would notice; a name in
# the list that no workflow carries is a rename the list did not follow.
#
# Honors WORKFLOWS_DIR_OVERRIDE (default: .github/workflows under the
# repo root), so the check can be pointed at a scratch copy.
#
# Exits 0 when the list and the names agree, 1 on any difference or a
# missing `completed` type, naming each workflow involved, and 2 when
# `yq` is missing or cannot read a workflow, or the directory holds no
# workflow besides the watchdog.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly WORKFLOWS_DIR="${WORKFLOWS_DIR_OVERRIDE:-${REPO_ROOT}/.github/workflows}"
readonly WATCHDOG="${WORKFLOWS_DIR}/ci-watchdog.yml"
# shellcheck source=scripts/lib/enumerate.sh
source "${REPO_ROOT}/scripts/lib/enumerate.sh"

if ! command -v yq >/dev/null 2>&1; then
  printf 'ci-watchdog-coverage: yq not found on PATH\n' >&2
  exit 2
fi
if [[ ! -f ${WATCHDOG} ]]; then
  printf 'ci-watchdog-coverage: %s not found\n' "${WATCHDOG}" >&2
  exit 2
fi

declare -a workflows=()
glob_into workflows 'workflows' "${WORKFLOWS_DIR}/*.yml" "${WORKFLOWS_DIR}/*.yaml"
declare -a others=()
for f in "${workflows[@]}"; do
  [[ ${f} == "${WATCHDOG}" ]] || others+=("${f}")
done
if ((${#others[@]} == 0)); then
  printf 'ci-watchdog-coverage: no workflow besides the watchdog under %s\n' "${WORKFLOWS_DIR}" >&2
  exit 2
fi

failures=0

# name -> file, so a finding names the file a missing name came from.
declare -A file_of=()
for f in "${others[@]}"; do
  if ! name="$(yq '.name // ""' "${f}")"; then
    printf 'ci-watchdog-coverage: yq could not read %s\n' "${f}" >&2
    exit 2
  fi
  if [[ -z ${name} ]]; then
    printf 'FAIL %s has no name: the watchdog list cannot name it\n' "${f##*/}" >&2
    failures=1
    continue
  fi
  file_of["${name}"]="${f##*/}"
done

declare -A listed=()
if ! listed_raw="$(yq '.on.workflow_run.workflows // [] | .[]' "${WATCHDOG}")"; then
  printf 'ci-watchdog-coverage: yq could not read %s\n' "${WATCHDOG}" >&2
  exit 2
fi
if [[ -n ${listed_raw} ]]; then
  while IFS= read -r name; do
    listed["${name}"]=1
  done <<<"${listed_raw}"
fi

for name in "${!file_of[@]}"; do
  if [[ -z ${listed["${name}"]+set} ]]; then
    printf 'FAIL workflow %q (%s) is missing from the ci-watchdog workflow_run list\n' \
      "${name}" "${file_of["${name}"]}" >&2
    failures=1
  fi
done
for name in "${!listed[@]}"; do
  if [[ -z ${file_of["${name}"]+set} ]]; then
    printf 'FAIL ci-watchdog workflow_run lists %q, which no other workflow is named\n' \
      "${name}" >&2
    failures=1
  fi
done

if ! types="$(yq --output-format=json --indent=0 '.on.workflow_run.types // []' "${WATCHDOG}")"; then
  printf 'ci-watchdog-coverage: yq could not read %s\n' "${WATCHDOG}" >&2
  exit 2
fi
if [[ ${types} != '["completed"]' ]]; then
  printf 'FAIL ci-watchdog workflow_run types are %s, want ["completed"]\n' "${types}" >&2
  failures=1
fi

if ((failures != 0)); then
  printf '\nci-watchdog-coverage: FAILURES\n' >&2
  exit 1
fi
printf 'OK   ci-watchdog workflow_run lists all %d other workflows\n' "${#file_of[@]}"
printf '\nci-watchdog-coverage: all passed\n'
