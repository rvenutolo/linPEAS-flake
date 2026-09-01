#!/usr/bin/env bash
# tests/check-flake-lock-provenance.test.sh
#
# Failure-mode harness for scripts/check-flake-lock-provenance.sh.
# Drives the check entirely off fixture files via the BASE_LOCK_FILE /
# HEAD_LOCK_FILE / BASE_FLAKE_NIX / HEAD_FLAKE_NIX env overrides, so no
# git history is touched.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-flake-lock-provenance.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-flake-lock-provenance"

# Every scenario runs under a wall-clock bound. The check resolves
# `follows` refs, and an unbounded resolver turns a small crafted lock
# into minutes of CPU; without this the suite would hang instead of
# reporting which fixture is slow. `timeout` reports 124 on a kill, so a
# blown bound surfaces as an exit-code mismatch naming the scenario.
readonly SCENARIO_TIMEOUT_SECS=20

# Both `flake.nix` sides default to the same fixture, which is what
# makes every pre-existing scenario mean what it always meant: identical
# declarations corroborate nothing, so a lock move is judged on the lock
# alone. Exported rather than passed per call so a scenario that forgets
# them cannot silently fall through to the repo's own `flake.nix` and
# make its verdict depend on the checkout's git state.
export BASE_FLAKE_NIX="${FIXTURES}/base.flake.nix"
export HEAD_FLAKE_NIX="${FIXTURES}/base.flake.nix"

# The gh CLI is replaced by a PATH stub whose behavior is selected with
# GH_STUB_MODE, so no network is touched. The default mode is `deny`:
# the stub exits 97 on any call, so every scenario that does not opt
# into a mode proves the check made no API call at all — an identity
# failure, a corroborated move, or a bump that moved no rev must all
# settle without asking GitHub anything. Exported for the same reason
# the flake.nix sides are: a scenario that forgets cannot fall through
# to the real gh and make its verdict depend on the network.
export PATH="${FIXTURES}/bin:${PATH}"
export GH_STUB_MODE=deny

failures=0

# @arg $1 scenario name  @arg $2 base fixture  @arg $3 head fixture
# @arg $4 expected exit  @arg $5 expected output substring (empty skips)
function run_pair_scenario() {
  local -r name="$1" base="$2" head="$3" expected_exit="$4" expected_msg="$5"
  local out_file outcome_file
  out_file="$(mktemp)"
  outcome_file="$(mktemp)"
  local actual_exit=0
  BASE_LOCK_FILE="${FIXTURES}/${base}" \
    HEAD_LOCK_FILE="${FIXTURES}/${head}" \
    timeout "${SCENARIO_TIMEOUT_SECS}" "${SCRIPT}" >"${out_file}" 2>&1 || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  if [[ ${actual_exit} -eq 124 && ${expected_exit} -ne 124 ]]; then
    printf 'FAIL: %s — killed after %ds; the check did not finish\n' \
      "${name}" "${SCENARIO_TIMEOUT_SECS}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_msg} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_msg}" "${out_file}"; then
    printf 'FAIL: %s — output missing %q\n' "${name}" "${expected_msg}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi
  harness_assert_record "${name}" "${expected_msg}" "${outcome_file}" "${out_file}"
  rm --force -- "${outcome_file}" "${out_file}"
}

# Runs a scenario whose head `flake.nix` differs from the base one, so
# the check sees a declared move to corroborate against. The base
# declaration stays at the shared fixture: corroboration is about what
# moved between the two sides, and anchoring the base is what keeps each
# scenario's declared move to exactly the one it names.
# @arg $1 scenario name  @arg $2 head lock fixture  @arg $3 head flake.nix fixture
# @arg $4 expected exit  @arg $5 expected output substring (empty skips)
function run_declared_scenario() {
  local -r name="$1" head="$2" head_nix="$3" expected_exit="$4" expected_msg="$5"
  HEAD_FLAKE_NIX="${FIXTURES}/${head_nix}" \
    run_pair_scenario "${name}" 'base.lock' "${head}" "${expected_exit}" "${expected_msg}"
}

# Runs a scenario under a named gh stub mode, so the ancestry probe sees
# the compare-API answer the scenario is about. Every other scenario
# stays under `deny`.
# @arg $1 scenario name  @arg $2 base fixture  @arg $3 head fixture
# @arg $4 gh stub mode  @arg $5 expected exit
# @arg $6 expected output substring (empty skips)
function run_ancestry_scenario() {
  local -r name="$1" base="$2" head="$3" mode="$4" expected_exit="$5" expected_msg="$6"
  GH_STUB_MODE="${mode}" \
    run_pair_scenario "${name}" "${base}" "${head}" "${expected_exit}" "${expected_msg}"
}

# @arg $1 scenario name  @arg $2 head fixture basename  @arg $3 expected exit
# @arg $4 expected stderr/stdout substring (empty skips)
# Thin wrapper over run_pair_scenario anchored at the default base lock.
function run_scenario() {
  local -r name="$1" head="$2" expected_exit="$3" expected_msg="$4"
  run_pair_scenario "${name}" 'base.lock' "${head}" "${expected_exit}" "${expected_msg}"
}

# @arg $1 scenario name  @arg $2 head fixture  @arg $3 expected exit
# @arg $4 expected output substring (empty skips)
# Thin wrapper over run_pair_scenario anchored at the follows-shaped base lock.
function run_follows_scenario() {
  local -r name="$1" head="$2" expected_exit="$3" expected_msg="$4"
  run_pair_scenario "${name}" 'base-follows.lock' "${head}" "${expected_exit}" "${expected_msg}"
}

# Points one of BASE_LOCK_FILE / HEAD_LOCK_FILE / BASE_FLAKE_NIX /
# HEAD_FLAKE_NIX at a caller-supplied payload path while the other three
# keep their valid default fixtures, so a scenario proves the
# could-not-run path fires on the override under test and nowhere else. Shared by the absent, unreadable, and
# directory-payload scenarios below — each supplies a different kind of
# broken path and lets this function drive the script and assert the
# outcome.
# @arg $1 scenario name  @arg $2 override var (BASE_LOCK_FILE or HEAD_LOCK_FILE)
# @arg $3 payload path to use for that var  @arg $4 expected exit
# @arg $5 expected output substring (empty skips)
function run_broken_lock_scenario() {
  local -r name="$1" var="$2" payload="$3" expected_exit="$4" expected_msg="$5"
  local out_file outcome_file
  out_file="$(mktemp)"
  outcome_file="$(mktemp)"
  local base_lock="${FIXTURES}/base.lock" head_lock="${FIXTURES}/base.lock"
  local base_nix="${FIXTURES}/base.flake.nix" head_nix="${FIXTURES}/base.flake.nix"
  case "${var}" in
  BASE_LOCK_FILE) base_lock="${payload}" ;;
  HEAD_LOCK_FILE) head_lock="${payload}" ;;
  BASE_FLAKE_NIX) base_nix="${payload}" ;;
  HEAD_FLAKE_NIX) head_nix="${payload}" ;;
  esac
  local actual_exit=0
  BASE_LOCK_FILE="${base_lock}" \
    HEAD_LOCK_FILE="${head_lock}" \
    BASE_FLAKE_NIX="${base_nix}" \
    HEAD_FLAKE_NIX="${head_nix}" \
    "${SCRIPT}" >"${out_file}" 2>&1 || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_msg}" "${outcome_file}" "${out_file}"
  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_msg} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_msg}" "${out_file}"; then
    printf 'FAIL: %s — output missing %q\n' "${name}" "${expected_msg}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi
  rm --force -- "${outcome_file}" "${out_file}"
}

# @arg $1 scenario name  @arg $2 override var  @arg $3 expected output substring
function run_absent_lock_scenario() {
  local -r name="$1" var="$2" expected_msg="$3"
  run_broken_lock_scenario "${name}" "${var}" "${FIXTURES}/does-not-exist.lock" 2 "${expected_msg}"
}

# Mode bits are no lever for root, so this scenario self-skips there —
# the directory scenario below covers the same could-not-run path for
# every user including root.
# @arg $1 scenario name  @arg $2 override var  @arg $3 expected output substring
function run_unreadable_lock_scenario() {
  local -r name="$1" var="$2" expected_msg="$3"
  if [[ ${EUID} -eq 0 ]]; then
    printf 'SKIP: %s (running as root — mode bits are no lever)\n' "${name}"
    return 0
  fi
  local payload
  payload="$(mktemp)"
  printf '{}' >"${payload}"
  chmod 000 -- "${payload}"
  run_broken_lock_scenario "${name}" "${var}" "${payload}" 2 "${expected_msg}"
  chmod 600 -- "${payload}"
  rm --force -- "${payload}"
}

# @arg $1 scenario name  @arg $2 override var  @arg $3 expected output substring
function run_directory_lock_scenario() {
  local -r name="$1" var="$2" expected_msg="$3"
  local payload
  payload="$(mktemp --directory)"
  run_broken_lock_scenario "${name}" "${var}" "${payload}" 2 "${expected_msg}"
  rm --recursive --force -- "${payload}"
}

function main() {
  # Every clean scenario asserts the whole summary line rather than the bare
  # `provenance OK`. The eight of them resolve different graphs — different
  # entry-point ids, follows depths, and tolerated transitive churn — and the
  # verdict alone renders all of that as the same observable outcome.
  # The routine bumps move a rev, so they are the scenarios that reach the
  # ancestry probe; each runs under the `ahead` stub, the answer a
  # fast-forward bump gets, and its summary counts the node it verified.
  run_ancestry_scenario 'routine bump passes' 'base.lock' 'head-routine.lock' ahead 0 \
    'provenance OK: entry "root"; top-level inputs resolved: 2 (0 via follows, max depth 0); shared nodes compared: 3; transitive churn tolerated: 0 added, 0 removed; flake.nix-corroborated moves: 0; ancestry probed: 1 verified, skipped: 0 corroborated, 0 non-github'
  # This head also moves alpha's rev. Under the `deny` stub that proves an
  # identity failure ends the run before any ancestry probe is made.
  run_scenario 'top-level owner change fails' 'head-toplevel-owner.lock' 1 \
    'FAIL: node repointed: alpha (original.owner: orgA -> evil)'
  run_scenario 'top-level type change fails' 'head-toplevel-type.lock' 1 \
    'FAIL: node repointed: alpha (locked.type: github -> git)'
  run_scenario 'top-level input added fails' 'head-toplevel-added.lock' 1 'FAIL: top-level input added: delta'
  run_scenario 'top-level input removed fails' 'head-toplevel-removed.lock' 1 'FAIL: top-level input removed: beta'
  run_scenario 'transitive repoint fails' 'head-transitive-repoint.lock' 1 'FAIL: node repointed: gamma (original.owner: orgC -> evil)'
  run_scenario 'transitive node added tolerated' 'head-transitive-added.lock' 0 \
    'provenance OK: entry "root"; top-level inputs resolved: 2 (0 via follows, max depth 0); shared nodes compared: 3; transitive churn tolerated: 1 added, 0 removed; flake.nix-corroborated moves: 0; ancestry probed: 0 verified, skipped: 0 corroborated, 0 non-github'
  run_scenario 'transitive node removed tolerated' 'head-transitive-removed.lock' 0 \
    'provenance OK: entry "root"; top-level inputs resolved: 2 (0 via follows, max depth 0); shared nodes compared: 2; transitive churn tolerated: 0 added, 1 removed; flake.nix-corroborated moves: 0; ancestry probed: 0 verified, skipped: 0 corroborated, 0 non-github'
  run_scenario 'garbage head json errors' 'head-garbage.lock' 2 ''
  run_scenario 'top-level rename same source' 'head-toplevel-renamed-same.lock' 0 \
    'provenance OK: entry "root"; top-level inputs resolved: 2 (0 via follows, max depth 0); shared nodes compared: 2; transitive churn tolerated: 1 added, 1 removed; flake.nix-corroborated moves: 0; ancestry probed: 0 verified, skipped: 0 corroborated, 0 non-github'
  run_scenario 'top-level rename + repoint fails' 'head-toplevel-renamed-repoint.lock' 1 \
    'FAIL: top-level input repointed: alpha (alpha -> alpha_2)'
  # The absent case exits 2 under the canonical could-not-run sentence,
  # which names the payload by kind — the override variable's own name,
  # never the fixture path a harness scenario happens to point it at.
  #
  # The head-side expectations carry a `flake-lock provenance head`
  # subject and the base-side ones carry none, which is the naming rule
  # itself rather than an oversight: on a live run the head read names
  # its source `flake.lock`, the same kind check-pre-commit-hooks-sha-parity.sh
  # names for the lock it reads, while the base read names
  # `<base ref>:flake.lock`, which no other script in the tree produces.
  # A subject is added where the source kind alone stops identifying the
  # payload, and nowhere else.
  run_absent_lock_scenario 'missing base errors' BASE_LOCK_FILE \
    'payload from BASE_LOCK_FILE not found'
  run_absent_lock_scenario 'missing head errors' HEAD_LOCK_FILE \
    'flake-lock provenance head: payload from HEAD_LOCK_FILE not found'
  # This is the reported defect: an unreadable payload dies under the
  # raw `cat` failure at exit 1 — the same code this script uses for a
  # genuine provenance violation.
  run_unreadable_lock_scenario 'unreadable base is a tooling error, not a violation' \
    BASE_LOCK_FILE 'payload from BASE_LOCK_FILE is not readable'
  run_unreadable_lock_scenario 'unreadable head is a tooling error, not a violation' \
    HEAD_LOCK_FILE 'flake-lock provenance head: payload from HEAD_LOCK_FILE is not readable'
  # A directory passes the `-f` guard's existence check but fails the
  # read; the guard's "not found" message does not distinguish that
  # from a genuinely absent path.
  run_directory_lock_scenario 'directory-payload base is a tooling error, not a violation' \
    BASE_LOCK_FILE 'payload from BASE_LOCK_FILE could not be read'
  run_directory_lock_scenario 'directory-payload head is a tooling error, not a violation' \
    HEAD_LOCK_FILE 'flake-lock provenance head: payload from HEAD_LOCK_FILE could not be read'

  run_ancestry_scenario 'follows routine bump passes' 'base-follows.lock' 'head-follows-routine.lock' ahead 0 \
    'provenance OK: entry "root"; top-level inputs resolved: 4 (1 via follows, max depth 1); shared nodes compared: 3; transitive churn tolerated: 0 added, 0 removed; flake.nix-corroborated moves: 0; ancestry probed: 2 verified, skipped: 0 corroborated, 0 non-github'
  run_follows_scenario 'string-to-array repoint fails' 'head-follows-string-to-array.lock' 1 'FAIL: top-level input repointed: gamma'
  run_follows_scenario 'array-to-array repoint fails' 'head-follows-array-change.lock' 1 'FAIL: top-level input repointed: beta (alpha -> gamma)'
  run_follows_scenario 'string-to-array same source passes' 'head-follows-string-to-array-same.lock' 0 \
    'provenance OK: entry "root"; top-level inputs resolved: 4 (2 via follows, max depth 1); shared nodes compared: 2; transitive churn tolerated: 0 added, 1 removed; flake.nix-corroborated moves: 0; ancestry probed: 0 verified, skipped: 0 corroborated, 0 non-github'
  run_follows_scenario 'dangling follows path fails' 'head-follows-dangling.lock' 1 \
    'FAIL: top-level input unresolvable (follows path names no such node): beta'
  run_follows_scenario 'cyclic follows fails' 'head-follows-cycle.lock' 1 \
    'FAIL: top-level input unresolvable (follows path exceeds nesting ceiling): beta'

  # Each `bN` input is a two-element path through `bN+1`, so a naive
  # resolver that re-walks every element costs 2^N for a lock under 1 KiB.
  # The step budget must stop it well inside the scenario timeout.
  run_pair_scenario 'branching follows exhausts step budget' \
    'base-follows-branching.lock' 'base-follows-branching.lock' 1 \
    'FAIL: top-level input unresolvable (follows step budget exhausted): b1'
  # A legal chain sitting exactly at the nesting ceiling: bounding total
  # work must not shorten how deep a legitimate `follows` chain may go. The
  # reported max depth is the evidence, and it is what tells an operator how
  # much headroom the ceiling still has.
  run_pair_scenario 'deep legal follows chain resolves' \
    'base-follows-deep.lock' 'base-follows-deep.lock' 0 \
    'provenance OK: entry "root"; top-level inputs resolved: 33 (32 via follows, max depth 32); shared nodes compared: 1; transitive churn tolerated: 0 added, 0 removed; flake.nix-corroborated moves: 0; ancestry probed: 0 verified, skipped: 0 corroborated, 0 non-github'

  run_scenario 'decoy renamed root fails' 'head-decoy-root.lock' 1 'FAIL: root node id changed: root -> realroot'
  run_scenario 'head .root missing errors' 'head-root-missing.lock' 2 'head flake.lock: .root missing or not a string (got null)'
  run_scenario 'head .root non-string errors' 'head-root-nonstring.lock' 2 'head flake.lock: .root missing or not a string (got {"bogus":1})'
  # Naming the entry point is what separates this from the plain routine
  # bump: the two resolve identically shaped graphs under different root ids.
  run_ancestry_scenario 'alt root id routine bump passes' 'base-alt-root.lock' 'head-alt-root-routine.lock' ahead 0 \
    'provenance OK: entry "top"; top-level inputs resolved: 2 (0 via follows, max depth 0); shared nodes compared: 3; transitive churn tolerated: 0 added, 0 removed; flake.nix-corroborated moves: 0; ancestry probed: 1 verified, skipped: 0 corroborated, 0 non-github'

  # Corroboration by flake.nix. The gate exists to bound the lock-only
  # bot path, so what separates a violation from a declared bump is
  # whether `flake.nix` moved the same input. Each scenario below pairs a
  # lock move with a declaration that does or does not account for it.
  # The declared move also carries a new rev. Under the `deny` stub that
  # proves a corroborated move is never probed: a channel move lands on a
  # different branch and a pin-back walks backwards, and both are the
  # declared consequence, not a smuggled one.
  run_declared_scenario 'declared repoint passes' \
    'head-alpha-declared-repoint.lock' 'head-alpha-repoint.flake.nix' 0 \
    'provenance OK: entry "root"; top-level inputs resolved: 2 (0 via follows, max depth 0); shared nodes compared: 3; transitive churn tolerated: 0 added, 0 removed; flake.nix-corroborated moves: 1; ancestry probed: 0 verified, skipped: 1 corroborated, 0 non-github'
  # Corroboration is per input name, not per PR: a declaration that moved
  # one input must not vouch for a second input moving alongside it.
  # This is the smuggling case the gate is really for.
  run_declared_scenario 'a declared repoint does not cover an undeclared sibling' \
    'head-alpha-beta-repoint.lock' 'head-alpha-repoint.flake.nix' 1 \
    'FAIL: node repointed: beta (original.ref: main -> next)'
  # The block-shaped declaration (`<name> = { url = ...; }`) is the other
  # half of the parser, and the one a nested `inputs.<x>.follows` line
  # sits inside — reading that nested line as a top-level source would
  # corroborate the wrong name.
  run_declared_scenario 'a block-shaped declaration corroborates its own input' \
    'head-alpha-beta-repoint.lock' 'head-beta-repoint.flake.nix' 1 \
    'FAIL: node repointed: alpha (original.ref: main -> next)'
  run_declared_scenario 'declared top-level input add passes' \
    'head-toplevel-added.lock' 'head-delta-added.flake.nix' 0 \
    'note: top-level input add/remove corroborated by flake.nix (tolerated): delta ((absent) -> github:orgD/delta/main)'
  run_declared_scenario 'declared top-level input removal passes' \
    'head-toplevel-removed.lock' 'head-beta-removed.flake.nix' 0 \
    'note: top-level input add/remove corroborated by flake.nix (tolerated): beta (github:orgB/beta/main -> (absent))'
  run_declared_scenario 'a declaration naming another input does not cover an add' \
    'head-alpha-declared-plus-delta-added.lock' 'head-alpha-repoint.flake.nix' 1 \
    'FAIL: top-level input added: delta'
  # `flake.nix` names no transitive node, so no declaration can reach
  # one. A PR that legitimately repoints a top-level input still cannot
  # carry a repoint deeper in the graph.
  run_declared_scenario 'a transitive repoint stays gated under a declared move' \
    'head-alpha-declared-plus-transitive.lock' 'head-alpha-repoint.flake.nix' 1 \
    'FAIL: node repointed: gamma (original.repo: gamma -> gamma-fork)'

  # A parser that stops finding declarations would corroborate nothing
  # and block every legitimate bump under a message naming the wrong
  # cause. An unparsable `flake.nix` is therefore a could-not-run on
  # both sides, not an empty map.
  run_broken_lock_scenario 'base flake.nix with no inputs block is a could-not-run' \
    BASE_FLAKE_NIX "${FIXTURES}/no-inputs.flake.nix" 2 \
    "BASE_FLAKE_NIX: no top-level 'inputs = {' block found"
  run_broken_lock_scenario 'head flake.nix with no inputs block is a could-not-run' \
    HEAD_FLAKE_NIX "${FIXTURES}/no-inputs.flake.nix" 2 \
    "HEAD_FLAKE_NIX: no top-level 'inputs = {' block found"
  run_absent_lock_scenario 'missing base flake.nix errors' BASE_FLAKE_NIX \
    'payload from BASE_FLAKE_NIX not found'
  run_absent_lock_scenario 'missing head flake.nix errors' HEAD_FLAKE_NIX \
    'flake-lock provenance head flake.nix: payload from HEAD_FLAKE_NIX not found'

  # Ancestry. Identity is clean in every scenario below; what varies is
  # what the compare API says about old..new, or whether the check asks
  # at all. A bump that moves only narHash/lastModified moves no rev and
  # must settle under `deny`.
  run_ancestry_scenario 'narHash-only bump makes no ancestry probe' 'base.lock' 'head-metadata-only.lock' deny 0 \
    'provenance OK: entry "root"; top-level inputs resolved: 2 (0 via follows, max depth 0); shared nodes compared: 3; transitive churn tolerated: 0 added, 0 removed; flake.nix-corroborated moves: 0; ancestry probed: 0 verified, skipped: 0 corroborated, 0 non-github'
  run_ancestry_scenario 'behind rev fails ancestry' 'base.lock' 'head-routine.lock' behind 1 \
    'FAIL: ancestry broken: alpha (orgA/alpha aaa111aaa111aaa111aaa111aaa111aaa111aaa1..aaa999aaa999aaa999aaa999aaa999aaa999aaa9: behind, ahead by 0, behind by 3)'
  run_ancestry_scenario 'diverged rev fails ancestry' 'base.lock' 'head-routine.lock' diverged 1 \
    'FAIL: ancestry broken: alpha (orgA/alpha aaa111aaa111aaa111aaa111aaa111aaa111aaa1..aaa999aaa999aaa999aaa999aaa999aaa999aaa9: diverged, ahead by 2, behind by 3)'
  # A 404 is the finding: the repo does not hold one of the two revs, or
  # is not the repo it was.
  run_ancestry_scenario 'rev unknown to repo fails ancestry' 'base.lock' 'head-routine.lock' not-found 1 \
    'FAIL: ancestry unknown: alpha (orgA/alpha: compare API reports no such commit or repository for aaa111aaa111aaa111aaa111aaa111aaa111aaa1..aaa999aaa999aaa999aaa999aaa999aaa999aaa9)'
  # Everything the API can do wrong short of a 404 is a could-not-run:
  # a transport or server error, a malformed payload with no status in
  # it, and a status the request cannot legitimately produce.
  run_ancestry_scenario 'compare API error is a could-not-run' 'base.lock' 'head-routine.lock' api-error 2 \
    'compare API failed for orgA/alpha aaa111aaa111aaa111aaa111aaa111aaa111aaa1...aaa999aaa999aaa999aaa999aaa999aaa999aaa9: gh: HTTP 500 upstream boom'
  run_ancestry_scenario 'malformed compare payload is a could-not-run' 'base.lock' 'head-routine.lock' malformed 2 \
    'unexpected payload shape from repos/orgA/alpha/compare/aaa111aaa111aaa111aaa111aaa111aaa111aaa1...aaa999aaa999aaa999aaa999aaa999aaa999aaa9?per_page=1: status: expected string, got null'
  run_ancestry_scenario 'unexpected compare status is a could-not-run' 'base.lock' 'head-routine.lock' unexpected-status 2 \
    "unexpected compare status 'sideways' for orgA/alpha"
  # A rev that is not a commit id never reaches the API route: it is
  # refused before interpolation, under `deny`, so the scenario also
  # proves no request carried it.
  run_ancestry_scenario 'non-40-hex rev is a could-not-run' 'base.lock' 'head-bad-rev.lock' deny 2 \
    'rev on alpha is not a 40-hex commit id: not-a-sha'
  # A node with no compare API to ask is named and counted, not probed
  # and not silently passed over.
  run_ancestry_scenario 'non-github rev move is named, not probed' 'base-mixed.lock' 'head-mixed-routine.lock' deny 0 \
    'note: ancestry not probed (non-github source, tolerated): delta (type=git)'

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
