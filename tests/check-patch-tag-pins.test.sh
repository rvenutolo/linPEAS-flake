#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-patch-tag-pins.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-patch-tag-pins"

# One message per failure mode, so a fixture that regresses into a
# different mode is reported as a mismatch instead of passing.
readonly MSG_NO_COMMENT="pin carries no version comment"
readonly MSG_NO_VERSION="pin comment names no version"
readonly MSG_MAJOR="pin comment names a major tag, not an exact patch tag"

failures=0

# assert_clean <fixture-basename>
assert_clean() {
  local fixture="$1" got_exit=0 stderr
  stderr="$(LINT_PATHS_OVERRIDE="${FIXTURES}/${fixture}" bash "${SCRIPT}" 2>&1)" || got_exit=$?
  if ((got_exit != 0)); then
    printf 'FAIL %s: exit %d, want 0\n  got: %s\n' "${fixture}" "${got_exit}" "${stderr}" >&2
    failures=$((failures + 1))
    return 0
  fi
  printf 'OK   %s (exit 0)\n' "${fixture}"
}

# assert_violation <fixture-basename> <want-stderr-substring>
assert_violation() {
  local fixture="$1" want="$2" got_exit=0 stderr
  stderr="$(LINT_PATHS_OVERRIDE="${FIXTURES}/${fixture}" bash "${SCRIPT}" 2>&1)" || got_exit=$?
  if ((got_exit == 0)); then
    printf 'FAIL %s: exit 0, want 1\n' "${fixture}" >&2
    failures=$((failures + 1))
    return 0
  fi
  if [[ ${stderr} != *"${want}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' "${fixture}" "${want}" "${stderr}" >&2
    failures=$((failures + 1))
    return 0
  fi
  printf 'OK   %s (exit %d)\n' "${fixture}" "${got_exit}"
}

assert_clean good.yml
assert_clean good-exact-pin.yml
assert_clean good-exception.yml

assert_violation bad.yml "${MSG_MAJOR}"
assert_violation bad-floating-major.yml "${MSG_MAJOR}"

# A SHA pin with no trailing comment at all leaves the intended tag
# unrecorded, so the SHA cannot be audited against a tag.
assert_violation bad-no-comment.yml "${MSG_NO_COMMENT}"

# A comment that names something other than a version (a branch, a
# channel) records no tag either.
assert_violation bad-nonversion-comment.yml "${MSG_NO_VERSION}"

# Empty reason after `patch-tag-exception:` does not satisfy the exception
# (a non-whitespace char must follow the colon), so it is still flagged.
assert_violation bad-empty-reason.yml "${MSG_MAJOR}"

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
  printf 'FAIL action.yaml composite: exit 0, want 1\n' >&2
  failures=$((failures + 1))
elif [[ ${actionyaml_stderr} != *"${MSG_MAJOR}"* ]]; then
  printf 'FAIL action.yaml composite: stderr missing %q\n  got: %s\n' \
    "${MSG_MAJOR}" "${actionyaml_stderr}" >&2
  failures=$((failures + 1))
else
  printf 'OK   action.yaml composite (exit %d)\n' "${got_exit}"
fi

# Default scan against a cwd holding no `.github` at all. Both find roots
# are relative, so this is what a lint invoked from the wrong directory
# sees: zero files enumerated. Scored as data that is a silent exit 0 over
# every pin in the repo, so it has to be a could-not-run instead.
EMPTY_SCAN_DIR="$(mktemp --directory)"
empty_scan_exit=0
empty_scan_stderr="$(cd "${EMPTY_SCAN_DIR}" && bash "${SCRIPT}" 2>&1)" || empty_scan_exit=$?
rm --recursive --force -- "${EMPTY_SCAN_DIR}"
if ((empty_scan_exit != 2)); then
  printf 'FAIL empty scan set: exit %d, want 2\n  got: %s\n' \
    "${empty_scan_exit}" "${empty_scan_stderr}" >&2
  failures=$((failures + 1))
elif [[ ${empty_scan_stderr} != *"enumerated 0 workflow / composite-action file(s)"* ]]; then
  printf 'FAIL empty scan set: stderr missing the breadth diagnostic\n  got: %s\n' \
    "${empty_scan_stderr}" >&2
  failures=$((failures + 1))
else
  printf 'OK   empty scan set (exit %d)\n' "${empty_scan_exit}"
fi

if ((failures > 0)); then
  printf '%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf 'all tests passed\n'
