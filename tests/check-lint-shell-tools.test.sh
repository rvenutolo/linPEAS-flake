#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-lint-shell-tools.sh"

# The guard validates the CURRENT PATH. Run inside the dev shell (default or
# .#lint) every expected tool is present, so the check must exit 0.
got_exit=0
out="$(bash "${SCRIPT}" 2>&1)" || got_exit=$?
if ((got_exit != 0)); then
  printf 'FAIL: expected exit 0, got %d\n  output: %s\n' "${got_exit}" "${out}" >&2
  exit 1
fi
printf 'OK   all expected lint-shell tools present\n'

# Negative path: with one required tool absent from PATH the guard must
# exit 1 and name the missing tool. This kills the mutants a happy-path-only
# test misses (e.g. EXPECTED=() or a hardcoded exit 0), which otherwise ship
# green. Build a symlink farm of every expected tool, then drop one.
farm="$(mktemp -d)"
for t in bash yq jq gh git shellcheck shfmt actionlint check-jsonschema sed grep awk; do
  ln -s "$(command -v "${t}")" "${farm}/${t}"
done
rm -f -- "${farm}/actionlint"
got_exit=0
out="$(env --unset=BASH_ENV PATH="${farm}" bash "${SCRIPT}" 2>&1)" || got_exit=$?
rm -rf -- "${farm}"
if ((got_exit != 1)); then
  printf 'FAIL: missing tool must exit 1, got %d\n  output: %s\n' "${got_exit}" "${out}" >&2
  exit 1
fi
if [[ ${out} != *"::error::lint shell missing tool on PATH: actionlint"* ]]; then
  printf 'FAIL: missing ::error:: line for actionlint\n  output: %s\n' "${out}" >&2
  exit 1
fi
printf 'OK   missing tool detected and named\n'

printf 'all tests passed\n'
