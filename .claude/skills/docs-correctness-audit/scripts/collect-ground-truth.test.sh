#!/usr/bin/env bash
# Test harness for collect-ground-truth.sh sweeps. Run from anywhere.
set -Eeuo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLECTOR="${HERE}/collect-ground-truth.sh"
# shellcheck disable=SC2034  # used by the ephemeral and link fixture checks below
REAL_REPO="$(git -C "${HERE}" rev-parse --show-toplevel)"
fails=0
check() { # $1=label $2=condition-already-evaluated(0/1)
  if [[ $2 -eq 0 ]]; then printf 'PASS: %s\n' "$1"; else
    printf 'FAIL: %s\n' "$1"
    fails=$((fails + 1))
  fi
}

# --- sourcing must not auto-run main ---
# shellcheck disable=SC1090  # COLLECTOR path is dynamic by design
src_out="$(
  source "${COLLECTOR}" 2>&1
  printf '__SOURCED__'
)"
case "${src_out}" in
*"===== FLAKE OUTPUTS"*) check "sourcing does not auto-run main" 1 ;;
*) check "sourcing does not auto-run main" 0 ;;
esac

# --- flake-output filter fixture ---
# Newer Nix emits a doc/output stub for every well-known output name and wraps
# the tree in "inventory". flake-parts materialises nixosModules,
# nixosConfigurations and legacyPackages as empty sets, and the renderer behind
# docs/reference/flake-outputs.md omits them — so a filter that keeps them makes
# every reader report that omission as generator drift.
# shellcheck disable=SC1090  # COLLECTOR path is dynamic by design
source "${COLLECTOR}"

flake_json='{
  "version": 3,
  "inventory": {
    "packages":            {"doc": "d", "output": {"children": {"x86_64-linux": {"children": {"linpeas": {"derivation": {"name": "linpeas"}}}}}}},
    "apps":                {"doc": "d", "output": {"children": {"x86_64-linux": {"filtered": true}}}},
    "lib":                 {"unknown": true},
    "nixosModules":        {"doc": "d", "output": {"children": {}}},
    "nixosConfigurations": {"doc": "d", "output": {"children": {}}},
    "legacyPackages":      {"doc": "d", "output": {"children": {"x86_64-linux": {"isLegacy": true}, "aarch64-linux": {"isLegacy": true}}}}
  }
}'

got="$(printf '%s' "${flake_json}" | filter_flake_outputs || true)"
rc=0
[[ ${got} == "outputs: apps, lib, packages" ]] || rc=1
check "flake filter drops empty and isLegacy-only outputs" "${rc}"

case "${got}" in
*nixosModules* | *nixosConfigurations* | *legacyPackages*) check "flake filter names no undefined output" 1 ;;
*) check "flake filter names no undefined output" 0 ;;
esac

# The pre-wrapper schema has no "inventory" key; the filter must still read it.
legacy_json='{"packages": {"doc": "d", "output": {"children": {"x86_64-linux": {"filtered": true}}}}}'
got_legacy="$(printf '%s' "${legacy_json}" | filter_flake_outputs || true)"
rc=0
[[ ${got_legacy} == "outputs: packages" ]] || rc=1
check "flake filter reads an un-wrapped inventory" "${rc}"

# --- ephemeral-token fixture ---
fx="$(mktemp -d)"
(
  cd "${fx}"
  git init -q && git config user.email t@t && git config user.name t
  mkdir -p docs
  cp "${REAL_REPO}/lychee.toml" .
  printf '# Doc\n\nPhase 3 work remains.\nTracking #388 here.\nclassDef x fill:#c8e6c9,stroke:#2e7d32\nEntity &#123; literal.\nsee [toc](#1-delete-the-thing).\nEvery call passes X-GitHub-Api-Version: 2022-11-28 header.\nUses SHA-256 digest.\n' >docs/eph.md
  # Left-boundary fixtures: each token embeds a banned shape inside a larger
  # word, which the guarded classes must not match. Guard failure here is the
  # false-positive class that trains a reader to ignore the sweep.
  printf 'The encoding is UTF-8 everywhere.\nA PDF-1.7 attachment.\nRecord ID5: opaque.\nSee abc#12 upstream.\nPhase   11 uses padded spacing.\n' >docs/guard.md
  # Exempt-region fixture: the same banned shapes, but quoted as documentation
  # rather than referenced. The real lint blanks all three regions; so must the
  # sweep, or every doc that documents the rules reports as violating them.
  {
    printf '# Rules\n\n'
    # shellcheck disable=SC2016 # literal backticks in human-readable prose
    printf 'A planning label looks like `Phase 7` and a PR ref like `#404`.\n'
    # shellcheck disable=SC2016 # literal backticks in human-readable prose
    printf 'A date span reads `2019-03-04` in prose.\n\n'
    printf 'Example of what NOT to write:\n\n'
    # shellcheck disable=SC2016 # literal fence markers, not expansions
    printf '```text\nPhase 5 landed in #505 on 2018-02-03\n```\n\n'
    printf '<!-- BEGIN sometable -->\nPhase 6 shipped in #606 on 2017-01-02\n<!-- END sometable -->\n\n'
    printf '~~~text\nPhase 4 landed in #707 on 2016-05-06\n~~~\n\n'
    # An inline-quoted BEGIN marker is documentation, not a block opener:
    # the prose after it must still be scanned, not blanked to the next END.
    # shellcheck disable=SC2016 # literal backticks in human-readable prose
    printf 'The marker `<!-- BEGIN x -->` opens a generated block.\nPhase 2 remains.\n'
  } >docs/exempt.md
  printf '# Changelog\n\n- #999 shipped 2024-01-01\n- Phase 9 cleanup\n' >CHANGELOG.md
  mkdir -p .claude
  printf 'Phase 8 work\n' >.claude/x.md
  git add -A
  git add --force .claude/x.md # force past the inherited global gitignore, mirroring the real repo's tracked .claude skill
  git commit -qm init
)
# shellcheck disable=SC1090  # COLLECTOR path is dynamic by design
eph="$(cd "${fx}" && source "${COLLECTOR}" && sweep_ephemeral_tokens)"
case "${eph}" in *"(planning-label)"*"Phase 3"*) check "flags Phase 3" 0 ;; *) check "flags Phase 3" 1 ;; esac
case "${eph}" in *"(pr-ref)"*"#388"*) check "flags #388" 0 ;; *) check "flags #388" 1 ;; esac
case "${eph}" in *"c8e6c9"*) check "suppresses hex color" 1 ;; *) check "suppresses hex color" 0 ;; esac
case "${eph}" in *"&#123"*) check "suppresses HTML entity" 1 ;; *) check "suppresses HTML entity" 0 ;; esac
case "${eph}" in *"#1-delete"*) check "suppresses anchor target" 1 ;; *) check "suppresses anchor target" 0 ;; esac
case "${eph}" in *"X-GitHub-Api-Version"*) check "suppresses api-version literal" 1 ;; *) check "suppresses api-version literal" 0 ;; esac
case "${eph}" in *"SHA-256"*) check "suppresses SHA-256" 1 ;; *) check "suppresses SHA-256" 0 ;; esac
case "${eph}" in *"#999"*) check "exempts CHANGELOG pr-ref" 1 ;; *) check "exempts CHANGELOG pr-ref" 0 ;; esac
case "${eph}" in *"2024-01-01"*) check "exempts CHANGELOG date" 1 ;; *) check "exempts CHANGELOG date" 0 ;; esac
case "${eph}" in *"Phase 9"*) check "fully exempts CHANGELOG planning-label" 1 ;; *) check "fully exempts CHANGELOG planning-label" 0 ;; esac
case "${eph}" in *"Phase 8"*) check "excludes .claude/ from sweep" 1 ;; *) check "excludes .claude/ from sweep" 0 ;; esac
# --- exempt regions must be blanked, not reported ---
case "${eph}" in *"Phase 7"*) check "exempts inline code span (planning-label)" 1 ;; *) check "exempts inline code span (planning-label)" 0 ;; esac
case "${eph}" in *"#404"*) check "exempts inline code span (pr-ref)" 1 ;; *) check "exempts inline code span (pr-ref)" 0 ;; esac
case "${eph}" in *"2019-03-04"*) check "exempts inline code span (date)" 1 ;; *) check "exempts inline code span (date)" 0 ;; esac
case "${eph}" in *"Phase 5"* | *"#505"* | *"2018-02-03"*) check "exempts fenced code block" 1 ;; *) check "exempts fenced code block" 0 ;; esac
case "${eph}" in *"Phase 6"* | *"#606"* | *"2017-01-02"*) check "exempts generated BEGIN/END block" 1 ;; *) check "exempts generated BEGIN/END block" 0 ;; esac
case "${eph}" in *"Phase 4"* | *"#707"* | *"2016-05-06"*) check "exempts tilde-fenced code block" 1 ;; *) check "exempts tilde-fenced code block" 0 ;; esac
case "${eph}" in *"(planning-label) Phase 2 remains"*) check "inline BEGIN mention does not open a block" 0 ;; *) check "inline BEGIN mention does not open a block" 1 ;; esac
# --- left-boundary guards mirror the real lint's classes ---
# Line-scoped: a hit in another class must not satisfy a guard assertion.
eph_absent() { # $1=label $2=ERE — the class+token pair must not appear
  if printf '%s\n' "${eph}" | grep -qE "$2"; then check "$1" 1; else check "$1" 0; fi
}
eph_present() { # $1=label $2=ERE — the class+token pair must appear
  if printf '%s\n' "${eph}" | grep -qE "$2"; then check "$1" 0; else check "$1" 1; fi
}
eph_absent "guard: UTF-8 is no planning-label" '\(planning-label\).*UTF-8'
eph_absent "guard: PDF-1.7 is no planning-label" '\(planning-label\).*PDF-1\.7'
eph_absent "guard: ID5: is no review-pass" '\(review-pass\).*ID5:'
eph_absent "guard: abc#12 is no pr-ref" '\(pr-ref\).*abc#12'
# The guard must not cost recall: a genuine label still hits, and the
# whitespace class matches the padded spacing a single literal space missed.
eph_present "guard keeps padded Phase 11" '\(planning-label\).*Phase   11'

# --- blanking must not shift reported line numbers ---
case "${eph}" in *"docs/eph.md:3"*) check "line numbers survive blanking" 0 ;; *) check "line numbers survive blanking" 1 ;; esac
rm -rf "${fx}"

# --- unterminated regions fail loud, mirroring the real lint ---
for kind in fence genblock; do
  fu="$(mktemp -d)"
  (
    cd "${fu}"
    git init -q && git config user.email t@t && git config user.name t
    mkdir -p docs
    if [[ ${kind} == fence ]]; then
      printf '# Bad\n\n```text\nnever closed\n' >docs/bad.md
    else
      printf '# Bad\n\n<!-- BEGIN sometable -->\nnever closed\n' >docs/bad.md
    fi
    git add -A && git commit -qm init
  )
  rc=0
  # shellcheck disable=SC1090  # COLLECTOR path is dynamic by design
  out="$( (cd "${fu}" && source "${COLLECTOR}" && sweep_ephemeral_tokens) 2>&1)" || rc=$?
  want='unterminated code fence'
  [[ ${kind} == genblock ]] && want='unterminated generated block'
  if [[ ${rc} -ne 0 && ${out} == *"${want}"* ]]; then
    check "unterminated ${kind} fails loud" 0
  else
    check "unterminated ${kind} fails loud" 1
  fi
  rm -rf "${fu}"
done

# --- internal-link fixture ---
fl="$(mktemp -d)"
(
  cd "${fl}"
  git init -q && git config user.email t@t && git config user.name t
  cp "${REAL_REPO}/lychee.toml" .
  mkdir -p docs
  printf '# A\n[bad](./nope.md)\n[badanchor](./b.md#missing)\n[ok](./b.md#real)\n[ext](https://example.com)\n' >docs/links.md
  printf '# Real\n' >docs/b.md
  # Tracked .claude/ tooling is a doc cluster, so its links are in scope;
  # the seeded-defect fixtures carry planted breakage and are not.
  mkdir -p .claude/skills/t/evals/seeded-defects/fixtures
  printf '# Skill\n[tooling-dead](./gone-tooling.md)\n' >.claude/skills/t/SKILL.md
  printf '# Seed\n[seeded-dead](./gone-seeded.md)\n' >.claude/skills/t/evals/seeded-defects/fixtures/f.md
  git add -A && git add --force .claude && git commit -qm init # force past the inherited global gitignore, mirroring the real repo's tracked .claude skill
)
# shellcheck disable=SC1090  # COLLECTOR path is dynamic by design
lnk="$(cd "${fl}" && source "${COLLECTOR}" && sweep_internal_links)"
case "${lnk}" in *"nope.md"*) check "flags broken relative link" 0 ;; *) check "flags broken relative link" 1 ;; esac
case "${lnk}" in *"missing"*) check "flags broken anchor" 0 ;; *) check "flags broken anchor" 1 ;; esac
case "${lnk}" in *"example.com"*) check "skips external URL" 1 ;; *) check "skips external URL" 0 ;; esac
case "${lnk}" in *"#real"*) check "resolves valid anchor (no error)" 1 ;; *) check "resolves valid anchor (no error)" 0 ;; esac
case "${lnk}" in *"gone-tooling.md"*) check "flags broken link in tracked .claude/ tooling" 0 ;; *) check "flags broken link in tracked .claude/ tooling" 1 ;; esac
case "${lnk}" in *"gone-seeded.md"*) check "skips seeded-defect fixtures" 1 ;; *) check "skips seeded-defect fixtures" 0 ;; esac
# A run that found broken links is a RESULT, not a failed sweep. Without this
# the substring checks above stay green even if the marker is emitted too.
case "${lnk}" in *"lychee failed"*) check "a broken-link run is not marked unusable" 1 ;; *) check "a broken-link run is not marked unusable" 0 ;; esac
rm -rf "${fl}"

# --- the two seeded-fixture filters must select the same set ---
# The collector's grep is only the first filter, and it protects only the
# consumers that go through this script. The link-check workflow hands the
# dotted trees straight to lychee, so there the exclude_path entry is the
# ONLY filter: a pattern narrower there link-checks a fixture tree for the
# breakage it was deliberately planted with, and the job goes red on the
# harness working. The two patterns are written in two files because they
# serve different consumers; this scenario is what keeps them one rule.
if ! command -v yq >/dev/null 2>&1; then
  check "yq available to read lychee.toml exclude_path" 1
else
  lychee_seeded="$(yq --input-format toml --output-format yaml \
    '.exclude_path[] | select(test("seeded-defects/fixtures"))' "${REAL_REPO}/lychee.toml")"
  # One entry, or the comparison below silently grades the wrong pattern.
  lines="$(printf '%s\n' "${lychee_seeded}" | grep --count . || true)"
  [[ ${lines} -eq 1 ]] && rc=0 || rc=1
  check "lychee.toml carries exactly one seeded-fixture exclusion" "${rc}"

  # Both the shipped tree and a hypothetical second skill's, plus paths that
  # must survive: a sibling doc in the same skill, the fixtures' own README
  # one level up, and an ordinary doc.
  seeded_paths=(
    '.claude/skills/docs-correctness-audit/evals/seeded-defects/fixtures/all-hit.md'
    '.claude/skills/second-skill/evals/seeded-defects/fixtures/f.md'
    '.claude/skills/docs-correctness-audit/evals/seeded-defects/README.md'
    '.claude/skills/docs-correctness-audit/references/repo-map.md'
    'docs/development/linting.md'
  )
  collector_sel="$(printf '%s\n' "${seeded_paths[@]}" | grep -E "^${RE_SEEDED_FIXTURES}" || true)"
  lychee_sel="$(printf '%s\n' "${seeded_paths[@]}" | grep -E "${lychee_seeded}" || true)"

  # Assert breadth, not just agreement: two empty selections agree vacuously,
  # which is exactly what a typo in either pattern produces.
  selected="$(printf '%s\n' "${collector_sel}" | grep --count . || true)"
  [[ ${selected} -eq 2 ]] && rc=0 || rc=1
  check "collector filter selects both fixture trees and nothing else" "${rc}"

  [[ ${collector_sel} == "${lychee_sel}" ]] && rc=0 || rc=1
  check "collector and lychee.toml filters select the same set" "${rc}"

  case "${lychee_sel}" in
  *second-skill*) check "lychee.toml excludes a second skill's fixture tree" 0 ;;
  *) check "lychee.toml excludes a second skill's fixture tree" 1 ;;
  esac
fi

# --- repo-map's restatements must track what they restate ---
# repo-map.md is the audit's ground truth: a cluster reader checks the tree
# against it, so a stale map does not misinform a human who might notice — it
# makes the audit itself read clean over real drift. The map is deliberately
# self-contained (a reader told to chase a second file mid-audit is a reader
# reading two files), so both restatements below stay where they are and are
# gated here instead of collapsed to pointers.
REPO_MAP="${HERE}/../references/repo-map.md"
map_section() { # $1=section number — emit that section's body
  sed -n "/^## $1\\./,/^## $(($1 + 1))\\./p" "${REPO_MAP}"
}

# Section 3 restates every generated doc and its generator. Ground truth is the
# tracked refresh-*.sh set plus git-cliff, which no refresh-*.sh covers.
tree_gen="$(cd "${REAL_REPO}" && git ls-files 'scripts/refresh-*.sh' | sed 's|^scripts/||' | sort)"
doc_gen="$(map_section 3 | grep -oE 'refresh-[a-z-]+\.sh' | sort -u)"

# Breadth first: an enumeration that came back empty would agree with an empty
# doc set, and a green run would mean the gate read nothing rather than that
# the table is right.
[[ -n ${tree_gen} ]] && rc=0 || rc=1
check "repo-map generator gate enumerates a non-empty refresh-*.sh set" "${rc}"

if [[ ${tree_gen} == "${doc_gen}" ]]; then rc=0; else
  rc=1
  printf '  tree-only: %s\n' "$(comm -23 <(echo "${tree_gen}") <(echo "${doc_gen}") | tr '\n' ' ')"
  printf '  doc-only:  %s\n' "$(comm -13 <(echo "${tree_gen}") <(echo "${doc_gen}") | tr '\n' ' ')"
fi
check "repo-map section 3 names exactly the tracked refresh-*.sh generators" "${rc}"

case "$(map_section 3)" in
*git-cliff*) check "repo-map section 3 keeps the one non-refresh generator row" 0 ;;
*) check "repo-map section 3 keeps the one non-refresh generator row" 1 ;;
esac

# Section 4 restates the sweep's classes. Ground truth is the collector's own
# _emit_eph calls in this directory, not the real lint's constants: section 4
# describes what the collector emits, and the collector deliberately mirrors
# rather than calls the lint.
# The marker is bold-plus-code at bullet start, not a bare code span: section 4
# also carries a caveats list whose bullets open with a bare backticked class
# name, and a bare-span matcher reads those as shape bullets.
coll_classes="$(grep -oE '_emit_eph [a-z-]+' "${COLLECTOR}" | cut -d' ' -f2 | sort -u)"
# shellcheck disable=SC2016 # literal backticks: the marker is a code span
doc_classes="$(map_section 4 | sed -n 's/^- \*\*`\([a-z-]*\)`\*\*.*/\1/p' | sort -u)"

[[ -n ${coll_classes} ]] && rc=0 || rc=1
check "repo-map class gate enumerates a non-empty _emit_eph set" "${rc}"

if [[ ${coll_classes} == "${doc_classes}" ]]; then rc=0; else
  rc=1
  printf '  collector-only: %s\n' "$(comm -23 <(echo "${coll_classes}") <(echo "${doc_classes}") | tr '\n' ' ')"
  printf '  map-only:       %s\n' "$(comm -13 <(echo "${coll_classes}") <(echo "${doc_classes}") | tr '\n' ' ')"
fi
check "repo-map section 4 carries a bullet per swept class" "${rc}"

# --- a lychee that cannot run at all must not read as a clean sweep ---
# lychee exits non-zero without printing an [ERROR] line when it refuses an
# input (a tracked doc deleted but not staged reaches this: git ls-files
# still names it). A status-blind sweep reports "(none)" — indistinguishable
# from a clean run — so the marker has to be distinct.
fx="$(mktemp -d)"
(
  cd "${fx}"
  git init -q && git config user.email t@t && git config user.name t
  cp "${REAL_REPO}/lychee.toml" .
  mkdir -p docs
  printf '# A\n' >docs/a.md
  git add -A && git commit -qm init
  rm docs/a.md # tracked in the index, absent from the worktree
)
# shellcheck disable=SC1090  # COLLECTOR path is dynamic by design
fail_out="$(cd "${fx}" && source "${COLLECTOR}" && sweep_internal_links)"
case "${fail_out}" in *"lychee failed"*) check "an unusable lychee run is not reported as clean" 0 ;; *) check "an unusable lychee run is not reported as clean" 1 ;; esac
rm -rf "${fx}"

# --- a sweep whose inputs are all excluded must not read as clean either ---
# lychee skips an excluded input with a warning and still exits 0, so an
# exclude_path entry matching a tracked doc shrinks the sweep silently.
fz="$(mktemp -d)"
(
  cd "${fz}"
  git init -q && git config user.email t@t && git config user.name t
  printf 'exclude_path = ["docs/"]\n' >lychee.toml
  mkdir -p docs
  printf '# A\n[ok](./b.md)\n' >docs/a.md
  printf '# B\n' >docs/b.md
  git add -A && git commit -qm init
)
# shellcheck disable=SC1090  # COLLECTOR path is dynamic by design
skip_out="$(cd "${fz}" && source "${COLLECTOR}" && sweep_internal_links)"
case "${skip_out}" in *"lychee skipped"*) check "an all-excluded sweep is not reported as clean" 0 ;; *) check "an all-excluded sweep is not reported as clean" 1 ;; esac
rm -rf "${fz}"

# --- broken links and a shrunken input set are independent signals ---
# Reporting only the errors would hide that the sweep covered fewer files
# than it claims, which is the state a reader is least able to detect.
fy="$(mktemp -d)"
(
  cd "${fy}"
  git init -q && git config user.email t@t && git config user.name t
  printf 'exclude_path = ["docs/skipme/"]\n' >lychee.toml
  mkdir -p docs/skipme
  printf '# A\n[bad](./gone.md)\n' >docs/a.md
  printf '# S\n' >docs/skipme/s.md
  git add -A && git commit -qm init
)
# shellcheck disable=SC1090  # COLLECTOR path is dynamic by design
both_out="$(cd "${fy}" && source "${COLLECTOR}" && sweep_internal_links)"
case "${both_out}" in *"lychee skipped"*) check "a skipped input is reported even when links are broken" 0 ;; *) check "a skipped input is reported even when links are broken" 1 ;; esac
case "${both_out}" in *"gone.md"*) check "the broken link is reported alongside the skip" 0 ;; *) check "the broken link is reported alongside the skip" 1 ;; esac
rm -rf "${fy}"

# --- ci.yml job listing is scoped to the jobs: block ---
# A bare 2-space-key grep also returns `on:` trigger names and `concurrency:`
# keys. Those read as job ids to a reader checking a doc's "CI job X" claim,
# which is the one thing this section exists to answer.
cj="$(mktemp -d)"
{
  printf 'name: ci\n\n'
  printf 'on:\n  push:\n    branches: [main]\n  pull_request:\n\n'
  printf 'concurrency:\n  group: ci-ref\n  cancel-in-progress: true\n\n'
  printf 'permissions: {}\n\n'
  printf 'jobs:\n'
  printf '  flake-check:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n'
  printf '  lint-doc-invariants:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n'
} >"${cj}/ci.yml"
# shellcheck disable=SC1090  # COLLECTOR path is dynamic by design
jobs_out="$(source "${COLLECTOR}" && list_ci_jobs "${cj}/ci.yml")"
case "${jobs_out}" in *"flake-check"*) check "lists a real job id" 0 ;; *) check "lists a real job id" 1 ;; esac
case "${jobs_out}" in *"lint-doc-invariants"*) check "lists every job id" 0 ;; *) check "lists every job id" 1 ;; esac
case "${jobs_out}" in *"push"*) check "excludes on: trigger names" 1 ;; *) check "excludes on: trigger names" 0 ;; esac
case "${jobs_out}" in *"pull_request"*) check "excludes on: pull_request" 1 ;; *) check "excludes on: pull_request" 0 ;; esac
case "${jobs_out}" in *"group"*) check "excludes concurrency keys" 1 ;; *) check "excludes concurrency keys" 0 ;; esac
case "${jobs_out}" in *"cancel-in-progress"*) check "excludes cancel-in-progress" 1 ;; *) check "excludes cancel-in-progress" 0 ;; esac
rm -rf "${cj}"

# --- script inventory reaches scripts/lib/ ---
# Tracked docs cite the sourced libraries by path. A `scripts/*.sh` glob does
# not recurse, so an inventory that stops at the top level makes every such
# citation read as a script that does not exist — a false "ghost script" a
# reader has no way to disprove from the bundle.
ls_dir="$(mktemp -d)"
mkdir -p "${ls_dir}/scripts/lib"
: >"${ls_dir}/scripts/check-thing.sh"
: >"${ls_dir}/scripts/refresh-thing.sh"
: >"${ls_dir}/scripts/lib/temp.sh"
: >"${ls_dir}/scripts/not-shell.md"
# shellcheck disable=SC1090  # COLLECTOR path is dynamic by design
scr="$(cd "${ls_dir}" && source "${COLLECTOR}" && list_scripts)"
case "${scr}" in *"check-thing.sh"*) check "lists a top-level entry point" 0 ;; *) check "lists a top-level entry point" 1 ;; esac
case "${scr}" in *"lib/temp.sh"*) check "lists a sourced library" 0 ;; *) check "lists a sourced library" 1 ;; esac
# The prefix is the point: a bare basename collapses lib/temp.sh into temp.sh
# and a reader can no longer tell which tree a citation names.
case "${scr}" in *$'\n'"temp.sh"* | "temp.sh"*) check "keeps the lib/ prefix" 1 ;; *) check "keeps the lib/ prefix" 0 ;; esac
case "${scr}" in *"not-shell.md"*) check "lists only shell scripts" 1 ;; *) check "lists only shell scripts" 0 ;; esac
# An unmatched glob must vanish rather than reach the output as its own pattern.
empty_dir="$(mktemp -d)"
mkdir -p "${empty_dir}/scripts"
# shellcheck disable=SC1090  # COLLECTOR path is dynamic by design
scr_empty="$(cd "${empty_dir}" && source "${COLLECTOR}" && list_scripts)"
case "${scr_empty}" in *"*"*) check "emits no literal glob when a tree is empty" 1 ;; *) check "emits no literal glob when a tree is empty" 0 ;; esac
rm -rf "${ls_dir}" "${empty_dir}"

# --- causal-history sweep mirrors RE_CAUSAL, no wider ---
# The real lint (scripts/lib/ephemeral-refs-scope.sh) excludes bare verbs and
# prepositions on purpose. A sweep that reports them hands the audit hits the
# lint never raises, and every one of those is a false positive to chase down.
cs="$(mktemp -d)"
(
  cd "${cs}"
  git init -q && git config user.email t@t && git config user.name t
  cp "${REAL_REPO}/lychee.toml" .
  mkdir -p docs
  printf '# Causal\n\nThis was previously a different shape.\n' >docs/flagged.md
  printf '# Sentence initial\n\nPreviously the gate ran on push.\n' >docs/initial.md
  printf '# Bare\n\nCompromise prior to publication is out of scope.\nThe operator swapped the token.\nThe interface was reshaped by the caller.\n' >docs/bare.md
  printf '# Blocking stays cased\n\nSee gap-12 for the deferred arm.\n' >docs/cased.md
  git add -A && git commit -qm init
)
# shellcheck disable=SC1090  # COLLECTOR path is dynamic by design
cau="$(cd "${cs}" && source "${COLLECTOR}" && sweep_ephemeral_tokens)"
case "${cau}" in *"(causal-history)"*"previously"*) check "flags previously" 0 ;; *) check "flags previously" 1 ;; esac
# The lint's advisory pass runs --ignore-case, so the sweep must too: the
# commonest causal form is sentence-initial, and a cased sweep misses all of it.
case "${cau}" in *"(causal-history)"*"Previously"*) check "flags sentence-initial Previously" 0 ;; *) check "flags sentence-initial Previously" 1 ;; esac
# Case folding must stay scoped to the advisory class — the blocking classes
# are cased in the lint, so a lowercased planning label is not a sweep hit.
case "${cau}" in *"gap-12"*) check "blocking classes stay case-sensitive" 1 ;; *) check "blocking classes stay case-sensitive" 0 ;; esac
case "${cau}" in *"prior to"*) check "does not flag bare 'prior to'" 1 ;; *) check "does not flag bare 'prior to'" 0 ;; esac
case "${cau}" in *"swapped"*) check "does not flag bare 'swapped'" 1 ;; *) check "does not flag bare 'swapped'" 0 ;; esac
case "${cau}" in *"reshaped"*) check "does not flag bare 'was reshaped'" 1 ;; *) check "does not flag bare 'was reshaped'" 0 ;; esac
rm -rf "${cs}"

# --- workflow-cron fixture ---
# A `cron:` inside a run: block is prose, not a schedule; the section must
# carry only `- cron:` list items.
cr="$(mktemp -d)"
mkdir -p "${cr}/wf"
printf 'on:\n  schedule:\n    - cron: "0 8 * * *" # daily\n' >"${cr}/wf/real.yml"
printf 'on:\n  workflow_dispatch:\njobs:\n  x:\n    steps:\n      - run: |\n          echo "the cron: lines under ci.md"\n' >"${cr}/wf/prose.yml"
# shellcheck disable=SC1090  # COLLECTOR path is dynamic by design
crons="$(cd "${cr}" && source "${COLLECTOR}" && list_workflow_crons wf)"
case "${crons}" in *'real.yml:    - cron: "0 8 * * *"'*) check "cron sweep lists schedule entries" 0 ;; *) check "cron sweep lists schedule entries" 1 ;; esac
case "${crons}" in *"prose.yml"*) check "cron sweep skips prose cron: mentions" 1 ;; *) check "cron sweep skips prose cron: mentions" 0 ;; esac
rm -rf "${cr}"

if [[ ${fails} -ne 0 ]]; then
  printf '\n%d FAILED\n' "${fails}"
  exit 1
fi
printf '\nALL PASSED\n'
