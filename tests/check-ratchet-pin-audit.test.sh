#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-ratchet-pin-audit.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/ratchet-pin-audit"

function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(WORKFLOW_PATH_OVERRIDE="${FIXTURES}/${fixture}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' \
      "${fixture}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' \
      "${fixture}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${fixture}"
}

expect good.yml 0 ""
expect bad-missing-permissions.yml 1 "top-level permissions must be {}"
expect bad-missing-concurrency.yml 1 "concurrency.group must be"
expect bad-missing-reason.yml 1 "notify body missing reason token"
expect bad-missing-dispatch.yml 1 "on: must include workflow_dispatch"

# --- classify-pin-ref.sh verdict tests -------------------------------
# Pure classifier: <tag> <pinned> <ref_object_sha> <ref_object_type>
# <deref_commit_sha>. Fake 40-hex SHAs keep the cases offline and
# deterministic; only equality/inequality and tag shape matter.
readonly CLASSIFY="${REPO_ROOT}/scripts/classify-pin-ref.sh"

function classify() {
  local -r desc="$1" want="$2"
  shift 2
  local got rc=0
  got="$(bash "${CLASSIFY}" "$@" 2>/dev/null)" || rc=$?
  if [[ ${want} == "<error>" ]]; then
    if [[ ${rc} -eq 0 ]]; then
      printf 'FAIL classify %s: expected non-zero exit\n' "${desc}" >&2
      return 1
    fi
    printf 'OK   classify %s (exit %d)\n' "${desc}" "${rc}"
    return 0
  fi
  if [[ ${rc} -ne 0 ]]; then
    printf 'FAIL classify %s: exit %d, want %s\n' "${desc}" "${rc}" "${want}" >&2
    return 1
  fi
  if [[ ${got} != "${want}" ]]; then
    printf 'FAIL classify %s: got %q want %q\n' "${desc}" "${got}" "${want}" >&2
    return 1
  fi
  printf 'OK   classify %s\n' "${desc}"
}

# tag-object pin of an unmoved annotated tag: pinned == tag object.
classify "tag-object pin, unmoved annotated tag" current \
  v9.0.0 dddddddddddddddddddddddddddddddddddddddd \
  dddddddddddddddddddddddddddddddddddddddd tag \
  cccccccccccccccccccccccccccccccccccccccc
# commit pin of an annotated tag: pinned == dereferenced commit.
classify "commit pin, annotated tag" current \
  v9.0.0 cccccccccccccccccccccccccccccccccccccccc \
  dddddddddddddddddddddddddddddddddddddddd tag \
  cccccccccccccccccccccccccccccccccccccccc
# lightweight tag: object is the commit, no deref.
classify "commit pin, lightweight tag" current \
  v4.3.1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa commit ""
# lightweight tag force-moved: object is a commit, pin matches neither
# the new ref object nor the (empty) deref commit -> drift.
classify "lightweight-tag force-move -> drift" drift \
  v4.3.1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb commit ""
# genuine force-move: pin matches neither new object nor new commit.
classify "genuine force-move -> drift" drift \
  v9.0.0 dddddddddddddddddddddddddddddddddddddddd \
  eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee tag \
  ffffffffffffffffffffffffffffffffffffffff
# floating major: skip regardless of SHAs.
classify "floating major -> skip" skip-floating-major \
  v31 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  7777777777777777777777777777777777777777 tag \
  8888888888888888888888888888888888888888
# patch tag with a major-looking prefix is NOT skipped.
classify "patch tag not over-skipped" drift \
  v31.2.0 1111111111111111111111111111111111111111 \
  2222222222222222222222222222222222222222 tag \
  3333333333333333333333333333333333333333
# usage error: too few args.
classify "usage error (too few args)" "<error>" v9.0.0 deadbeef

printf 'all tests passed\n'
