#!/usr/bin/env bash
# scripts/check-run-block-pyflakes-required.sh
#
# @description Guard: fail if any GitHub Actions `run:` block
# invokes python (python/python3/pip/pip3) while pyflakes is not
# wired into the actionlint hook. Today no python run: exists,
# so this is a passive gate. The day someone adds a python run:,
# this fails with a pointer to the runbook describing how to
# wire pyflakes.
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

# Heuristic: look for python/python3/pip used as an *invoked
# command* in a GitHub Actions YAML file. The token must appear
# in a command-position context — either right after `run:` on a
# single-line step, or as the first non-whitespace token of a
# line inside a `run: |` block, optionally preceded by an
# env-var assignment (`VAR=val `) and/or a path prefix
# (`/usr/bin/`, `./venv/bin/`, etc.). The token must also be
# followed by whitespace or end-of-line, so that bare mentions
# inside echo strings (`echo "no python here"`) and YAML key
# names (`python-version`, `pip-cache`) don't trip the guard.
#
# We grep the whole file rather than parse YAML — the cost of a
# false positive is one human glance at the runbook, which is
# acceptable.
#
# `cmd_prefix` matches an optional command wrapper (`sudo`,
# `env`, `time`, `nice`) followed by zero or more `VAR=val `
# env assignments, optionally followed by an absolute or
# relative-path prefix (`/usr/bin/`, `./venv/bin/`, etc.).
violations=0
cmd_prefix='((sudo|env|time|nice)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*((/|\./|\.\./)[^[:space:]]*/)?'
pattern="(run:[[:space:]]+${cmd_prefix}|^[[:space:]]*([|>-][[:space:]]+)?${cmd_prefix})(python3?|pip3?)([[:space:]]|\$)"
for f in "${files[@]}"; do
  # grep exits 1 when no lines match; the `if` guard keeps us
  # alive under `set -e`. A single invocation captures both the
  # presence check and the matched lines.
  if matches="$(grep -nE "${pattern}" -- "${f}")"; then
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
