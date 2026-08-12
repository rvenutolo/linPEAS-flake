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
#   LINT_ALLOW_EMPTY_SCAN — set to 1 to accept an empty scan set.
#
# Exits 0 on clean, 1 if any python invocation found, 2 when the scan set
# could not be enumerated or came back empty.

set -Eeuo pipefail
IFS=$'\n\t'

readonly RUNBOOK="docs/actionlint-embedded-linters.md"

# The enumeration is captured rather than piped straight into `mapfile`,
# which reports the status of `mapfile` and never of `find`. A scan root
# that is not there makes `find` exit 1 with no paths on stdout, and the
# breadth line below then states `scanned 0 workflow file(s)` at exit 0 —
# a report of how little was read, printed as though it were a verdict on
# what was read. Both a failed producer and an empty one are could-not-run
# here, so each gets its own diagnostic.
declare -a files=()
scan_out=""
if [[ -n ${PYFLAKES_GUARD_SCAN_ROOT_OVERRIDE:-} ]]; then
  scan_root="${PYFLAKES_GUARD_SCAN_ROOT_OVERRIDE}"
  if ! scan_out="$(find "${scan_root}" \
    -type f \( -name '*.yml' -o -name '*.yaml' \) -print)"; then
    printf 'run-block-pyflakes: find failed enumerating %s\n' "${scan_root}" >&2
    exit 2
  fi
else
  repo_root="$(git rev-parse --show-toplevel)"
  scan_root="${repo_root}/.github"
  # Each root is scanned only when it is there, so a repo carrying
  # workflows and no composite actions is not a tooling failure.
  for root in "${repo_root}/.github/workflows" "${repo_root}/.github/actions"; do
    [[ -d ${root} ]] || continue
    if ! root_out="$(find "${root}" \
      -type f \( -name '*.yml' -o -name '*.yaml' \) -print)"; then
      printf 'run-block-pyflakes: find failed enumerating %s\n' "${root}" >&2
      exit 2
    fi
    scan_out+="${root_out}"$'\n'
  done
fi
# An empty capture read by `<<<` still yields one empty line, so blank
# entries are dropped here and the count below is of real paths.
while IFS= read -r scanned_path; do
  [[ -z ${scanned_path} ]] && continue
  files+=("${scanned_path}")
done <<<"${scan_out}"
if ((${#files[@]} == 0)) && [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
  printf 'run-block-pyflakes: enumerated 0 workflow file(s) under %s — with nothing read the guard has no verdict to give; set LINT_ALLOW_EMPTY_SCAN=1 if this scan root is deliberately empty\n' \
    "${scan_root}" >&2
  exit 2
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
run_blocks=0
python_lines=0
cmd_prefix='((sudo|env|time|nice)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*((/|\./|\.\./)[^[:space:]]*/)?'
pattern="(run:[[:space:]]+${cmd_prefix}|^[[:space:]]*([|>-][[:space:]]+)?${cmd_prefix})(python3?|pip3?)([[:space:]]|\$)"
# A `run:` key, either as its own mapping key or opening a step in a
# sequence. Counting these reports how much command text the guard
# actually had in front of it.
run_block_pattern='^[[:space:]]*(-[[:space:]]+)?run:([[:space:]]|$)'
for f in "${files[@]}"; do
  # grep --count prints 0 and exits 1 on no match; `|| true` keeps the
  # zero and keeps us alive under `set -e`.
  run_blocks=$((run_blocks + $(grep --count --extended-regexp -- \
    "${run_block_pattern}" "${f}" || true)))
  # grep exits 1 when no lines match; the `if` guard keeps us
  # alive under `set -e`. A single invocation captures both the
  # presence check and the matched lines.
  if matches="$(grep -nE "${pattern}" -- "${f}")"; then
    printf 'FOUND python invocation in %s:\n%s\n\n' "${f}" "${matches}" >&2
    violations=$((violations + 1))
    python_lines=$((python_lines + $(wc -l <<<"${matches}")))
  fi
done

# A passing run is silent about how much it looked at, so a scan root
# whose workflows are all `uses:` steps reads exactly like one full of
# shell that happens to avoid python — and a scan that matched no files
# at all reads like both. State the breadth covered: files read, command
# blocks in them, and the python invocations among those.
printf 'run-block-pyflakes: scanned %d workflow file(s), %d run: block(s); %d python invocation(s)\n' \
  "${#files[@]}" "${run_blocks}" "${python_lines}"

if [[ ${violations} -gt 0 ]]; then
  printf 'FAIL: %d workflow file(s) invoke python in run: blocks,\n' \
    "${violations}" >&2
  printf 'but pyflakes is not wired into the actionlint hook.\n' >&2
  printf 'Wire pyflakes per the runbook before merging: %s\n' "${RUNBOOK}" >&2
  exit 1
fi

exit 0
