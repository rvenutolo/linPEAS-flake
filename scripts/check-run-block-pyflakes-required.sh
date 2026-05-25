#!/usr/bin/env bash
# scripts/check-run-block-pyflakes-required.sh
#
# @description Guard: fail if any GitHub Actions `run:` block
# invokes python (python/python3/pip) while pyflakes is not wired
# into the actionlint hook. Today no python run: exists, so this
# is a passive gate. The day someone adds a python run:, this
# fails with a pointer to the runbook describing how to wire
# pyflakes.
#
# Scope: .github/workflows/*.{yml,yaml} and
#        .github/actions/**/action.{yml,yaml}
#
# Env overrides (test-only):
#   PYFLAKES_GUARD_SCAN_ROOT_OVERRIDE — alternate directory tree
#     containing workflow/action YAML files (overrides the default
#     repo-root .github/ scan).
#
# Exits 0 on clean, 1 if any python invocation found.

set -Eeuo pipefail
IFS=$'\n\t'

readonly RUNBOOK="docs/actionlint-embedded-linters.md"

if [[ -n ${PYFLAKES_GUARD_SCAN_ROOT_OVERRIDE:-} ]]; then
  mapfile -t files < <(
    find "${PYFLAKES_GUARD_SCAN_ROOT_OVERRIDE}" \
      -type f \( -name '*.yml' -o -name '*.yaml' \) -print
  )
else
  repo_root="$(git rev-parse --show-toplevel)"
  mapfile -t files < <(
    find "${repo_root}/.github/workflows" \
      "${repo_root}/.github/actions" \
      -type f \( -name '*.yml' -o -name '*.yaml' \) -print 2>/dev/null
  )
fi

if [[ ${#files[@]} -eq 0 ]]; then
  exit 0
fi

# Heuristic: look for python/python3/pip as the first token of a
# command inside a run: block. We grep the whole file rather than
# parse YAML — the cost of a false positive is one human glance
# at the runbook, which is acceptable.
violations=0
for f in "${files[@]}"; do
  # Match lines that look like a shell command invoking python/pip.
  # Skip comment lines (#...) and YAML keys.
  if grep -nE \
    '^\s*([|>-]\s+)?(python3?|pip)(\s|$)' \
    -- "${f}" >/dev/null 2>&1; then
    matches="$(grep -nE \
      '^\s*([|>-]\s+)?(python3?|pip)(\s|$)' \
      -- "${f}")"
    printf 'FOUND python invocation in %s:\n%s\n\n' "${f}" "${matches}" >&2
    violations=$((violations + 1))
  fi
done

if [[ ${violations} -gt 0 ]]; then
  printf 'FAIL: %d workflow file(s) invoke python in run: blocks,\n' \
    "${violations}" >&2
  printf 'but pyflakes is not wired into the actionlint hook.\n' >&2
  printf 'Wire pyflakes per the runbook before merging: %s\n' "${RUNBOOK}" >&2
  exit 1
fi

exit 0
