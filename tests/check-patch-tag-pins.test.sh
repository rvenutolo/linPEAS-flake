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

# action.yaml composite via default scan (no LINT_PATHS_OVERRIDE): fixed
# once the .github/actions discovery covers action.yaml, not just
# action.yml.
ACTIONYAML_DIR="$(mktemp --directory)"
mkdir --parents "${ACTIONYAML_DIR}/.github/actions/sample-yaml"
cat >"${ACTIONYAML_DIR}/.github/actions/sample-yaml/action.yaml" <<'ACTION_EOF'
name: sample-yaml
runs:
  using: composite
  steps:
    - uses: github/codeql-action/init@03e4368ac7daa2bd82b3e85262f3bf87ee112f57 # v3
ACTION_EOF
got_exit=0
actionyaml_stderr="$(cd "${ACTIONYAML_DIR}" && bash "${SCRIPT}" 2>&1)" || got_exit=$?
rm --recursive --force -- "${ACTIONYAML_DIR}"
if ((got_exit == 0)); then
  printf 'FAIL action.yaml composite: expected non-zero exit\n' >&2
  exit 1
fi
if [[ ${actionyaml_stderr} != *"${WANT_MSG}"* ]]; then
  printf 'FAIL action.yaml composite: stderr missing %q\n  got: %s\n' "${WANT_MSG}" "${actionyaml_stderr}" >&2
  exit 1
fi
printf 'OK   action.yaml composite (exit %d)\n' "${got_exit}"

printf 'all tests passed\n'
