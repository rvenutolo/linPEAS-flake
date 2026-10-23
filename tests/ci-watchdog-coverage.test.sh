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
# The live tree is checked first, then three must-fail scenarios, each
# on a copy of the workflows written to a temporary directory: a name
# removed from the list, a stale name added to it, and the wrong
# `types`. Each must exit 1 and name what is wrong, so a check that
# stopped reading the list could not stay green.
#
# Exits 0 when every scenario behaves, 1 otherwise, and 2 when `yq` is
# missing.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly LIVE_DIR="${REPO_ROOT}/.github/workflows"
# shellcheck source=scripts/lib/enumerate.sh
source "${REPO_ROOT}/scripts/lib/enumerate.sh"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"

if ! command -v yq >/dev/null 2>&1; then
  printf 'ci-watchdog-coverage: yq not found on PATH\n' >&2
  exit 2
fi

# @description Compare the watchdog's workflow_run list in one workflows
# directory with the names of the other workflows there. Prints one
# FAIL line per difference.
# @arg $1 workflows directory
# @exitcode 0 the list and the names agree and the type is `completed`
# @exitcode 1 a difference or a wrong type
# @exitcode 2 the directory has no watchdog or no other workflow, or yq
#   cannot read a file
function check_coverage() {
  local -r dir="$1"
  local -r watchdog="${dir}/ci-watchdog.yml"
  local failed=0 f name listed_raw types
  if [[ ! -f ${watchdog} ]]; then
    printf 'ci-watchdog-coverage: %s not found\n' "${watchdog}"
    return 2
  fi
  local -a workflows=() others=()
  glob_into workflows 'workflows' "${dir}/*.yml" "${dir}/*.yaml"
  for f in "${workflows[@]}"; do
    [[ ${f} == "${watchdog}" ]] || others+=("${f}")
  done
  if ((${#others[@]} == 0)); then
    printf 'ci-watchdog-coverage: no workflow besides the watchdog under %s\n' "${dir}"
    return 2
  fi

  # name -> file, so a finding names the file a missing name came from.
  local -A file_of=() listed=()
  for f in "${others[@]}"; do
    if ! name="$(yq '.name // ""' "${f}")"; then
      printf 'ci-watchdog-coverage: yq could not read %s\n' "${f}"
      return 2
    fi
    if [[ -z ${name} ]]; then
      printf 'FAIL %s has no name: the watchdog list cannot name it\n' "${f##*/}"
      failed=1
      continue
    fi
    file_of["${name}"]="${f##*/}"
  done

  if ! listed_raw="$(yq '.on.workflow_run.workflows // [] | .[]' "${watchdog}")"; then
    printf 'ci-watchdog-coverage: yq could not read %s\n' "${watchdog}"
    return 2
  fi
  if [[ -n ${listed_raw} ]]; then
    while IFS= read -r name; do
      listed["${name}"]=1
    done <<<"${listed_raw}"
  fi

  for name in "${!file_of[@]}"; do
    if [[ -z ${listed["${name}"]+set} ]]; then
      printf 'FAIL workflow %q (%s) is missing from the ci-watchdog workflow_run list\n' \
        "${name}" "${file_of["${name}"]}"
      failed=1
    fi
  done
  for name in "${!listed[@]}"; do
    if [[ -z ${file_of["${name}"]+set} ]]; then
      printf 'FAIL ci-watchdog workflow_run lists %q, which no other workflow is named\n' "${name}"
      failed=1
    fi
  done

  if ! types="$(yq --output-format=json --indent=0 '.on.workflow_run.types // []' "${watchdog}")"; then
    printf 'ci-watchdog-coverage: yq could not read %s\n' "${watchdog}"
    return 2
  fi
  if [[ ${types} != '["completed"]' ]]; then
    printf 'FAIL ci-watchdog workflow_run types are %s, want ["completed"]\n' "${types}"
    failed=1
  fi

  if ((failed == 0)); then
    printf 'coverage ok: the workflow_run list names all %d other workflows\n' "${#file_of[@]}"
  fi
  return "${failed}"
}

TMP_DIR="$(mktemp --directory)"
readonly TMP_DIR
trap 'rm --recursive --force -- "${TMP_DIR}"' EXIT

failures=0

# @description Run check_coverage on one directory and assert its exit
# code and one substring of its output.
# @arg $1 scenario name  @arg $2 directory  @arg $3 expected exit code
# @arg $4 expected substring
function scenario() {
  local -r name="$1" dir="$2" want_rc="$3" want="$4"
  local -r out="${TMP_DIR}/${name}.out"
  local rc=0
  (check_coverage "${dir}") >"${out}" 2>&1 || rc=$?
  harness_assert_record "${name}" "${want}" "${out}"
  if [[ ${rc} -ne ${want_rc} ]]; then
    printf 'FAIL %s: exit %d, want %d\n' "${name}" "${rc}" "${want_rc}" >&2
    sed 's/^/  /' "${out}" >&2
    failures=1
    return
  fi
  if ! grep --quiet --fixed-strings -- "${want}" "${out}"; then
    printf 'FAIL %s: output does not contain %q\n' "${name}" "${want}" >&2
    sed 's/^/  /' "${out}" >&2
    failures=1
    return
  fi
  printf 'OK   %s (exit %d)\n' "${name}" "${rc}"
}

# @description Copy the live workflows into a fresh scenario directory
# and apply one yq edit to the copied watchdog.
# @arg $1 scenario directory name  @arg $2 yq expression
function mutated_copy() {
  local -r dir="${TMP_DIR}/$1"
  mkdir -- "${dir}"
  cp -- "${LIVE_DIR}"/*.yml "${dir}/"
  yq --inplace "$2" "${dir}/ci-watchdog.yml"
  printf '%s' "${dir}"
}

scenario live "${LIVE_DIR}" 0 'coverage ok: the workflow_run list names all'
scenario missing-name "$(mutated_copy missing 'del(.on.workflow_run.workflows[] | select(. == "links"))')" 1 \
  'FAIL workflow links (links.yml) is missing from the ci-watchdog workflow_run list'
scenario stale-name "$(mutated_copy stale '.on.workflow_run.workflows += ["no-such-workflow"]')" 1 \
  'FAIL ci-watchdog workflow_run lists no-such-workflow, which no other workflow is named'
scenario wrong-types "$(mutated_copy types '.on.workflow_run.types = ["requested"]')" 1 \
  'FAIL ci-watchdog workflow_run types are ["requested"], want ["completed"]'

harness_assert_verify || failures=1

if ((failures != 0)); then
  printf '\nci-watchdog-coverage: FAILURES\n' >&2
  exit 1
fi
printf '\nci-watchdog-coverage: all passed\n'
