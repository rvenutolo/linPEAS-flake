#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-patch-tag-pins.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-patch-tag-pins"

LINT_PATHS_OVERRIDE="${FIXTURES}/good.yml" bash "${SCRIPT}"
printf 'OK   good.yml\n'

readonly WANT_MSG="major-tag comment without patch-tag-exception:"

got_exit=0
bad_stderr="$(LINT_PATHS_OVERRIDE="${FIXTURES}/bad.yml" bash "${SCRIPT}" 2>&1)" || got_exit=$?
if ((got_exit == 0)); then
  printf 'FAIL bad.yml: expected non-zero exit\n' >&2
  exit 1
fi
if [[ ${bad_stderr} != *"${WANT_MSG}"* ]]; then
  printf 'FAIL bad.yml: stderr missing %q\n  got: %s\n' "${WANT_MSG}" "${bad_stderr}" >&2
  exit 1
fi
printf 'OK   bad.yml (exit %d)\n' "${got_exit}"

# Empty reason after `patch-tag-exception:` does not satisfy the exception
# (a non-whitespace char must follow the colon), so it is still flagged.
got_exit=0
empty_stderr="$(LINT_PATHS_OVERRIDE="${FIXTURES}/bad-empty-reason.yml" bash "${SCRIPT}" 2>&1)" || got_exit=$?
if ((got_exit == 0)); then
  printf 'FAIL bad-empty-reason.yml: expected non-zero exit\n' >&2
  exit 1
fi
if [[ ${empty_stderr} != *"${WANT_MSG}"* ]]; then
  printf 'FAIL bad-empty-reason.yml: stderr missing %q\n  got: %s\n' "${WANT_MSG}" "${empty_stderr}" >&2
  exit 1
fi
printf 'OK   bad-empty-reason.yml (exit %d)\n' "${got_exit}"

printf 'all tests passed\n'
