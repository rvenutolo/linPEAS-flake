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

# Banned-token sweep over tracked docs. Canonical list: references/repo-map.md §4.
# Authoritative: a hit here is real; readers flag it without re-judging by eye.
EPH_FILES=()
_emit_eph() { # $1=category $2=ERE — emits "file:line\t(category) <trimmed line>"
  grep -HnE "$2" -- "${EPH_FILES[@]}" 2>/dev/null |
    sed -E "s/^([^:]+:[0-9]+):[[:space:]]*/\1	($1) /" || true
}
sweep_ephemeral_tokens() {
  mapfile -t EPH_FILES < <(git ls-files '*.md' | grep -vE '^(\.claude/|tests/fixtures/|docs/_data/|CHANGELOG\.md$|docs/releases\.md$)' || true)
  if [[ ${#EPH_FILES[@]} -eq 0 ]]; then
    echo '(none)'
    return 0
  fi
  local hits
  hits="$(
    {
      _emit_eph planning-label 'GAP-[0-9]+|P[0-9]+\.[0-9]+|Wave-P?[0-9]+|Phase [0-9]+|AU-P-[0-9]+|SC-POST-[0-9]+|plan [0-9]+|F-[0-9]+'
      _emit_eph review-pass '\(D[0-9]+\)|\(L[0-9]+[,) ]|Per D[0-9]+|D[0-9]+:'
      _emit_eph ad-hoc-ticket 'DH-[0-9]+|NC-[A-Z][0-9]+|[A-Z]{2,3}-[0-9]+' |
        grep -vE '(SHA|UTF|RFC|ISO|BASE)-[0-9]+' || true
      _emit_eph date '[0-9]{4}-[0-9]{2}-[0-9]{2}|(January|February|March|April|May|June|July|August|September|October|November|December) [0-9]{4}|Q[1-4] [0-9]{4}' |
        grep -vE 'X-GitHub-Api-Version: [0-9]{4}-[0-9]{2}-[0-9]{2}' || true
      _emit_eph causal-history 'prior to|previously|Migration note|was reshaped|Tightened from|swapped|switched (from|to)|legacy .* was deleted|added in #?[0-9]+|post-PR #[0-9]+'
      _emit_eph pr-ref '#[0-9]+|PR #[0-9]+|issue #[0-9]+' |
        grep -vE '(fill|stroke|color):#[0-9a-fA-F]{3,8}|&#[0-9]+;|#[0-9]+-' || true
      _emit_eph claude-path '\.claude/'
    } | sort -u || true
  )"
  if [[ -z ${hits} ]]; then echo '(none)'; else printf '%s\n' "${hits}"; fi
}

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

  section "EPHEMERAL-TOKEN HITS (banned shapes in tracked docs; authoritative — see repo-map §4)"
  sweep_ephemeral_tokens
  echo '(SUPPRESSED deterministically: fill:/stroke:#hex, &#NNN;, #N-anchor targets,'
  echo ' SHA/UTF/RFC/ISO/BASE-NNN, X-GitHub-Api-Version date literal.'
  echo ' Excludes .claude/ tooling, CHANGELOG.md + docs/releases.md (historical records),'
  echo ' tests/fixtures. A hit above is authoritative — flag it.)'
}

if [[ ${BASH_SOURCE[0]} == "${0:-}" ]]; then
  main "$@"
fi
