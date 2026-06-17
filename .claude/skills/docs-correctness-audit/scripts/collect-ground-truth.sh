#!/usr/bin/env bash
# collect-ground-truth.sh — bundled with the docs-correctness-audit skill.
#
# @description Emit, in one labeled dump, the repo ground-truth bundle the audit
# shares with every cluster reader: flake outputs, just recipes, scripts,
# workflows, the ci.yml top-level job list, lint-group membership, a union
# allowlist of all valid CI job/check names, workflow crons, and the
# required-check context count. Run this ONCE and hand its output to every
# reader, so a path/recipe/output/job/cron named in a doc is checked against one
# authoritative list instead of re-derived per agent. The job list, lint-group
# map, and union allowlist are the load-bearing facts: a doc calling a lint-group
# member check a standalone "required CI job" (mislabel), or naming a "CI job"
# that exists in no workflow at all (ghost), is the drift no freshness gate
# catches.
set -Eeuo pipefail
IFS=$'\n\t'

section() { printf '\n===== %s =====\n' "$1"; }

main() {
  REPO_ROOT="$(git rev-parse --show-toplevel)"
  cd "${REPO_ROOT}"

  section "FLAKE OUTPUTS (nix flake show)"
  if ! nix flake show --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
for k, v in sorted(d.items()):
    if isinstance(v, dict):
        print(k + ": " + ", ".join(sorted(v.keys())))
    else:
        print(k)
' 2>/dev/null; then
    nix flake show 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
  fi

  section "JUST RECIPES (just --list)"
  just --list 2>/dev/null | sed 's/^ *//'

  section "SCRIPTS (scripts/*.sh)"
  for f in scripts/*.sh; do basename "${f}"; done

  section "WORKFLOWS (.github/workflows)"
  ls .github/workflows/

  section "CI.YML TOP-LEVEL JOBS (ci.yml's own jobs; see union allowlist below for ALL valid names)"
  grep -nE '^  [a-z][a-z0-9-]+:' .github/workflows/ci.yml | sed 's/: *$//'

  section "LINT-GROUP MEMBERSHIP (.github/lint-groups.yml)"
  if [[ -f .github/lint-groups.yml ]]; then
    grep -vE '^[[:space:]]*#' .github/lint-groups.yml | grep -vE '^[[:space:]]*$'
  else
    echo '(no .github/lint-groups.yml)'
  fi

  section "VALID CI JOB / CHECK NAMES (union: every workflow job id + every lint-group member)"
  {
    # job ids from the jobs: block of every workflow (not just ci.yml)
    for wf in .github/workflows/*.yml; do
      awk '
        /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
        /^[A-Za-z]/ { in_jobs = 0 }
        in_jobs && /^  [A-Za-z0-9_-]+:/ {
          name = $0
          sub(/:.*/, "", name)
          gsub(/[[:space:]]/, "", name)
          print name
        }
      ' "${wf}"
    done
    # lint-group member check basenames (list items under each group)
    if [[ -f .github/lint-groups.yml ]]; then
      grep -E '^[[:space:]]*-[[:space:]]' .github/lint-groups.yml |
        sed -E "s/^[[:space:]]*-[[:space:]]*//; s/[[:space:]].*$//; s/[\"']//g"
    fi
  } | sort -u
  echo '(GHOST CHECK: a name a doc calls a "CI job" or "required check" that is'
  echo ' ABSENT from this list exists in no workflow and no lint group — high severity.)'

  section "WORKFLOW CRONS (authoritative schedules; ci.md table must match)"
  grep -H 'cron:' .github/workflows/*.yml 2>/dev/null | sed 's#\.github/workflows/##'

  section "REQUIRED-CHECK CONTEXTS (ruleset)"
  ruleset='.github/rulesets/protect-main.json'
  if [[ -f ${ruleset} ]]; then
    printf 'protect-main.json context count: %s\n' "$(grep -c '"context"' "${ruleset}")"
  else
    echo '(no ruleset file at .github/rulesets/protect-main.json)'
  fi
}

if [[ ${BASH_SOURCE[0]} == "${0:-}" ]]; then
  main "$@"
fi
