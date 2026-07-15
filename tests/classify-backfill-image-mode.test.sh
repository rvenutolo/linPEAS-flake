#!/usr/bin/env bash
# tests/classify-backfill-image-mode.test.sh
#
# Verdict + failure-mode matrix for
# scripts/classify-backfill-image-mode.sh. Pure classifier: four
# presence tokens (amd64@ghcr amd64@hub arm64@ghcr arm64@hub), each
# "present" or "absent". Offline and deterministic.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/classify-backfill-image-mode.sh"

failures=0

# @arg $1 description  @arg $2 expected stdout, or "<error>" for non-zero exit
# remaining args: passed through to the classifier
function classify() {
  local -r desc="$1" want="$2"
  shift 2
  local got rc=0
  got="$(bash "${SCRIPT}" "$@" 2>/dev/null)" || rc=$?
  if [[ ${want} == "<error>" ]]; then
    if [[ ${rc} -eq 0 ]]; then
      printf 'FAIL %s: expected non-zero exit, got 0\n' "${desc}" >&2
      failures=1
      return
    fi
    printf 'OK   %s (exit %d)\n' "${desc}" "${rc}"
    return
  fi
  if [[ ${rc} -ne 0 ]]; then
    printf 'FAIL %s: exit %d, want %s\n' "${desc}" "${rc}" "${want}" >&2
    failures=1
    return
  fi
  if [[ ${got} != "${want}" ]]; then
    printf 'FAIL %s: got %q want %q\n' "${desc}" "${got}" "${want}" >&2
    failures=1
    return
  fi
  printf 'OK   %s\n' "${desc}"
}

classify "all present -> full" full present present present present
classify "all absent -> none" none absent absent absent absent
classify "one arch present (partial)" "<error>" present present absent absent
classify "one registry present (partial)" "<error>" present absent present absent
classify "single tag present (partial)" "<error>" present absent absent absent
classify "single tag absent (partial)" "<error>" absent present present present
classify "too few args" "<error>" present present present
classify "too many args" "<error>" present present present present present
classify "bad token" "<error>" present present present maybe

if [[ ${failures} -ne 0 ]]; then
  printf '\nclassify-backfill-image-mode: FAILURES\n' >&2
  exit 1
fi
printf '\nclassify-backfill-image-mode: all passed\n'
