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
  git add -A && git commit -qm init
)
# shellcheck disable=SC1090  # COLLECTOR path is dynamic by design
lnk="$(cd "${fl}" && source "${COLLECTOR}" && sweep_internal_links)"
case "${lnk}" in *"nope.md"*) check "flags broken relative link" 0 ;; *) check "flags broken relative link" 1 ;; esac
case "${lnk}" in *"missing"*) check "flags broken anchor" 0 ;; *) check "flags broken anchor" 1 ;; esac
case "${lnk}" in *"example.com"*) check "skips external URL" 1 ;; *) check "skips external URL" 0 ;; esac
case "${lnk}" in *"#real"*) check "resolves valid anchor (no error)" 1 ;; *) check "resolves valid anchor (no error)" 0 ;; esac
rm -rf "${fl}"

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

if [[ ${fails} -ne 0 ]]; then
  printf '\n%d FAILED\n' "${fails}"
  exit 1
fi
printf '\nALL PASSED\n'
