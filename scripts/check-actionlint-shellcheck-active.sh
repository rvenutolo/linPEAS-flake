#!/usr/bin/env bash
# scripts/check-actionlint-shellcheck-active.sh
#
# @description Canary: assert actionlint's embedded shellcheck
# integration is wired. Runs the (wrapper-pinned) actionlint
# binary against a fixture workflow containing a planted SC2086
# violation; fails if the SC2086 code does not appear in output.
#
# If this script fails, the actionlint hook has silently stopped
# invoking shellcheck on `run:` blocks. See
# docs/actionlint-embedded-linters.md.
#
# Env overrides (test-only):
#   ACTIONLINT_SMOKE_FIXTURE_OVERRIDE — alternate fixture path
#
# Exits 0 on clean, 1 on any failure.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly DEFAULT_FIXTURE="${REPO_ROOT}/tests/fixtures/actionlint-shellcheck-smoke.yml"
readonly FIXTURE="${ACTIONLINT_SMOKE_FIXTURE_OVERRIDE:-${DEFAULT_FIXTURE}}"
readonly RUNBOOK="docs/actionlint-embedded-linters.md"

if [[ ! -f ${FIXTURE} ]]; then
  printf 'ERROR: fixture not found: %s\n' "${FIXTURE}" >&2
  exit 1
fi

if ! command -v actionlint >/dev/null 2>&1; then
  printf 'ERROR: actionlint not on PATH. Run inside the devShell.\n' >&2
  exit 1
fi

output_file="$(mktemp)"
trap 'rm -f -- "${output_file}"' EXIT

# actionlint exits non-zero when it surfaces findings; that's the
# expected path here. We disable -e for the invocation so we can
# inspect output regardless of exit code.
set +e
actionlint "${FIXTURE}" >"${output_file}" 2>&1
set -e

if grep --quiet --fixed-strings "SC2086" "${output_file}"; then
  exit 0
fi

printf 'FAIL: SC2086 not found in actionlint output for fixture %s\n' "${FIXTURE}" >&2
printf 'The actionlint hook is no longer invoking shellcheck on run: blocks.\n' >&2
printf 'See %s for diagnosis steps.\n' "${RUNBOOK}" >&2
printf '\n--- actionlint output ---\n' >&2
cat -- "${output_file}" >&2
exit 1
