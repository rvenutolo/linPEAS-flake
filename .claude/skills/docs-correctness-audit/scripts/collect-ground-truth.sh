#!/usr/bin/env bash
# collect-ground-truth.sh — bundled with the docs-correctness-audit skill.
#
# @description Emit, in one labeled dump, the repo ground-truth bundle the audit
# shares with every cluster reader: flake outputs, just recipes, scripts,
# workflows, the ci.yml top-level job list, lint-group membership, a union
# allowlist of all valid CI job/check names, workflow crons, the
# required-check context count, an ephemeral-token sweep over tracked
# docs, and an internal link/anchor check. Run this ONCE and hand its output to every
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
#
# The sweep reads prose only. Before matching, it blanks the three regions the
# repo's own lint (scripts/check-ephemeral-refs.sh) exempts: fenced code blocks,
# generated BEGIN/END bodies, and inline code spans. Without that pass the sweep
# reports a doc that *documents* a banned shape as an example — a table of
# banned token shapes, a generated hook table — as though it carried one, which
# is a false positive on every hit. Blanking preserves line numbering, so a
# reported line number still points at the right line.
#
# This mirrors the real lint rather than calling it, so the sweep still works on
# a fixture repo that does not contain it. The real lint remains the final
# authority: when the two disagree, believe `scripts/check-ephemeral-refs.sh`.
EPH_FILES=()
EPH_SCAN_DIR=""

# @description Emit one file with its exempt regions blanked, line for line.
_eph_blank() { # $1=path
  awk '
    /^[[:space:]]*```/                { in_fence = !in_fence; print ""; next }
    in_fence                          { print ""; next }
    /<!--[[:space:]]*BEGIN[[:space:]]/ { in_gen = 1; print ""; next }
    /<!--[[:space:]]*END[[:space:]]/   { in_gen = 0; print ""; next }
    in_gen                            { print ""; next }
    { line = $0; gsub(/`[^`]*`/, " ", line); print line }
  ' <"$1"
}

# @description Materialise blanked copies of EPH_FILES under a temp mirror, so
#              each category grep runs once over prose-only text.
_eph_prepare() {
  local f dir
  EPH_SCAN_DIR="$(mktemp -d)"
  for f in "${EPH_FILES[@]}"; do
    dir="${f%/*}"
    [[ ${dir} == "${f}" ]] && dir="."
    mkdir -p "${EPH_SCAN_DIR}/${dir}"
    _eph_blank "${f}" >"${EPH_SCAN_DIR}/${f}"
  done
}

_emit_eph() { # $1=category $2=ERE — emits "file:line\t(category) <trimmed line>"
  (cd "${EPH_SCAN_DIR}" && grep -HnE "$2" -- "${EPH_FILES[@]}" 2>/dev/null) |
    sed -E "s/^([^:]+:[0-9]+):[[:space:]]*/\1	($1) /" || true
}
sweep_ephemeral_tokens() {
  mapfile -t EPH_FILES < <(git ls-files '*.md' | grep -vE '^(\.claude/|tests/fixtures/|docs/_data/|CHANGELOG\.md$|docs/releases\.md$)' || true)
  if [[ ${#EPH_FILES[@]} -eq 0 ]]; then
    echo '(none)'
    return 0
  fi
  _eph_prepare
  local hits
  hits="$(
    {
      _emit_eph planning-label 'GAP-[0-9]+|P[0-9]+\.[0-9]+|Wave-P?[0-9]+|Phase [0-9]+|AU-P-[0-9]+|SC-POST-[0-9]+|plan [0-9]+|F-[0-9]+'
      _emit_eph review-pass '\(D[0-9]+\)|\(L[0-9]+[,) ]|Per D[0-9]+|D[0-9]+:'
      _emit_eph ad-hoc-ticket 'DH-[0-9]+|NC-[A-Z][0-9]+|[A-Z]{2,3}-[0-9]+' |
        grep -vE '(SHA|UTF|RFC|ISO|BASE)-[0-9]+' || true
      _emit_eph date '[0-9]{4}-[0-9]{2}-[0-9]{2}|(January|February|March|April|May|June|July|August|September|October|November|December) [0-9]{4}|Q[1-4] [0-9]{4}' |
        grep -vE 'X-GitHub-Api-Version: [0-9]{4}-[0-9]{2}-[0-9]{2}' || true
      # Mirrors RE_CAUSAL in scripts/lib/ephemeral-refs-scope.sh. Bare verbs
      # and prepositions (`prior to`, `swapped`, `was reshaped`) are excluded
      # there on purpose, so including them here would report hits the real
      # lint never raises.
      _emit_eph causal-history 'previously|Migration note|Tightened from|switched (from|to)|legacy .* was deleted|added in #?[0-9]+|post-PR #?[0-9]+'
      _emit_eph pr-ref '#[0-9]+|PR #[0-9]+|issue #[0-9]+' |
        grep -vE '(fill|stroke|color):#[0-9a-fA-F]{3,8}|&#[0-9]+;|#[0-9]+-' || true
      _emit_eph claude-path '\.claude/'
    } | sort -u || true
  )"
  [[ -n ${EPH_SCAN_DIR} ]] && rm -rf "${EPH_SCAN_DIR}"
  EPH_SCAN_DIR=""
  if [[ -z ${hits} ]]; then echo '(none)'; else printf '%s\n' "${hits}"; fi
}

# Internal link + anchor resolution via lychee (offline; external URLs skipped).
# Run from a tmp cwd so lychee's gitignored .lycheecache never lands in the repo.
sweep_internal_links() {
  if ! command -v lychee >/dev/null 2>&1; then
    echo '(lychee not found — internal-link sweep skipped)'
    return 0
  fi
  local repo_root tmp errs
  repo_root="$(git rev-parse --show-toplevel)"
  local files=()
  mapfile -t files < <(git ls-files '*.md' | grep -vE '^(\.claude/|tests/fixtures/|docs/_data/)' || true) # mirrors ephemeral sweep scope; neither depends on lychee.toml for docs-scope decisions
  if [[ ${#files[@]} -eq 0 ]]; then
    echo '(none)'
    return 0
  fi
  tmp="$(mktemp -d)"
  errs="$(
    cd "${tmp}" &&
      lychee --config "${repo_root}/lychee.toml" --offline \
        --include-fragments=anchor-only --cache=false --no-progress \
        "${files[@]/#/${repo_root}/}" 2>&1 |
      grep '\[ERROR\]' |
        sed "s#file://${repo_root}/##g" || true
  )"
  rm -rf "${tmp}"
  if [[ -z ${errs} ]]; then echo '(none)'; else printf '%s\n' "${errs}"; fi
}

# @description Read `nix flake show --json` on stdin, emit "outputs: a, b, c".
#
# Newer Nix wraps the tree in an "inventory" key and emits a stub for every
# well-known output name whether or not this flake defines it, so a naive key
# dump reports nixosModules, nixosConfigurations and legacyPackages as outputs
# this flake has. flake-parts does create those three, but empty, and the
# renderer behind docs/reference/flake-outputs.md omits them — a reader handed
# the naive dump reports that omission as generator drift. Keep only outputs
# holding something: a child with real entries, a derivation, or a system Nix
# declined to enumerate. A bare isLegacy marker is a placeholder for an empty
# legacyPackages set, not content.
filter_flake_outputs() {
  python3 -c '
import json, sys

def substantive(node):
    if not isinstance(node, dict):
        return bool(node)
    if node.get("filtered") or "derivation" in node:
        return True
    kids = node.get("children")
    if isinstance(kids, dict):
        return any(substantive(c) for c in kids.values())
    return not node.get("isLegacy", False) and bool(node)

def defined(v):
    if not isinstance(v, dict) or "output" not in v:
        return True
    return substantive(v["output"])

d = json.load(sys.stdin)
tree = d["inventory"] if isinstance(d.get("inventory"), dict) else d
names = sorted(k for k, v in tree.items() if defined(v))
print("outputs: " + ", ".join(names))
'
}

list_ci_jobs() { # $1=workflow path — emits "<line>:  <job-id>" for the jobs: block only
  # Scoped to the jobs: block. A bare 2-space-key grep also returns `on:`
  # trigger names and `concurrency:` keys, which read as job ids to someone
  # checking a doc's "CI job X" claim against this section.
  awk '
    /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
    /^[A-Za-z]/ { in_jobs = 0 }
    in_jobs && /^  [A-Za-z0-9_-]+:/ {
      name = $0
      sub(/:.*/, "", name)
      gsub(/[[:space:]]/, "", name)
      printf "%d:  %s\n", NR, name
    }
  ' "$1"
}

main() {
  REPO_ROOT="$(git rev-parse --show-toplevel)"
  cd "${REPO_ROOT}"

  section "FLAKE OUTPUTS (nix flake show)"
  if ! nix flake show --json 2>/dev/null | filter_flake_outputs 2>/dev/null; then
    nix flake show 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
  fi

  section "JUST RECIPES (just --list)"
  just --list 2>/dev/null | sed 's/^ *//'

  section "SCRIPTS (scripts/*.sh)"
  for f in scripts/*.sh; do basename "${f}"; done

  section "WORKFLOWS (.github/workflows)"
  ls .github/workflows/

  section "CI.YML TOP-LEVEL JOBS (ci.yml's own jobs; see union allowlist below for ALL valid names)"
  list_ci_jobs .github/workflows/ci.yml

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

  section "EPHEMERAL-TOKEN HITS (banned shapes in tracked-doc PROSE; see repo-map §4)"
  sweep_ephemeral_tokens
  echo '(Prose only: fenced code blocks, generated BEGIN/END bodies, and inline'
  echo ' code spans are blanked before matching, mirroring check-ephemeral-refs.sh.'
  echo ' Also suppressed: fill:/stroke:/color:#hex, &#NNN;, #N-anchor targets,'
  echo ' SHA/UTF/RFC/ISO/BASE-NNN, X-GitHub-Api-Version date literal.'
  echo ' Excludes .claude/ tooling, CHANGELOG.md + docs/releases.md (historical records),'
  echo ' tests/fixtures.'
  # shellcheck disable=SC2016 # literal backticks in human-readable prose
  echo ' NOT authoritative — `scripts/check-ephemeral-refs.sh` is. Run it and'
  echo ' believe its exit code; treat anything here it does not report as a'
  echo ' false positive. causal-history is advisory-only even in the real lint.)'

  section "UNRESOLVED INTERNAL LINKS / ANCHORS (lychee --offline; external skipped; authoritative)"
  sweep_internal_links
}

if [[ ${BASH_SOURCE[0]} == "${0:-}" ]]; then
  main "$@"
fi
