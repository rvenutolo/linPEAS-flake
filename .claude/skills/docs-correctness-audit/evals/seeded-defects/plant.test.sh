#!/usr/bin/env bash
# Exercises plant.sh end-to-end without running the audit.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plant="$here/plant.sh"
results="$here/results"
fail=0
check() { if eval "$2"; then echo "ok - $1"; else
  echo "NOT ok - $1"
  fail=1
fi; }

# Planting must leave the primary tree exactly as it found it. Recording the
# tracked-file status up front and comparing after asserts that, where a bare
# "tree is clean" test instead refuses to run for anyone holding uncommitted
# edits — which is everyone who runs the harness-group runner before pushing.
# shellcheck disable=SC2034 # read via check()'s eval of the assertion string below, not a direct expansion here
primary_before="$(git -C "$here" status --porcelain --untracked-files=no)"

# Clean slate, then plant.
"$plant" --clean >/dev/null 2>&1 || true
"$plant" >/dev/null

wt="$(cat "$results/worktree-path.txt")"
manifest="$results/manifest-resolved.json"

check "worktree exists" "[ -d '$wt' ]"
check "skill present in worktree" "[ -f '$wt/.claude/skills/docs-correctness-audit/SKILL.md' ]"
check "manifest has 9 seeds" "[ \"\$(jq 'length' '$manifest')\" = 9 ]"
check "every seed has a numeric line" \
  "[ \"\$(jq '[.[] | select((.line|type)==\"number\" and .line>0)] | length' '$manifest')\" = 9 ]"

# Every sentinel (non-empty) must be present in the worktree at its recorded file.
while IFS=$'\t' read -r f s; do
  [ -n "$s" ] || continue
  check "sentinel '$s' planted in $f" "grep -qF -- '$s' '$wt/$f'"
done < <(jq -r '.[] | "\(.file)\t\(.sentinel)"' "$manifest")

# Primary tree must be unchanged by planting (tracked files).
check "primary tree unchanged by planting" \
  "[ \"\$(git -C '$here' status --porcelain --untracked-files=no)\" = \"\$primary_before\" ]"

# Teardown removes the worktree.
"$plant" --clean >/dev/null
check "worktree removed after --clean" "[ ! -d '$wt' ]"

# A seeds anchor is a verbatim copy of a sentence the rest of the repo is free
# to reword. An anchor that no longer resolves has to be a loud failure: a seed
# that quietly does not plant shrinks the recall denominator without saying so.
bad_rc=0
# shellcheck disable=SC2034 # read via check()'s eval of the assertion string below, not a direct expansion here
bad_out="$(SEEDS_OVERRIDE="$here/fixtures/seeds-bad-anchor.json" "$plant" 2>&1)" ||
  bad_rc=$?
check "unresolvable anchor fails the plant" "[ '$bad_rc' -ne 0 ]"
check "unresolvable anchor names the miss" \
  "printf '%s' \"\$bad_out\" | grep -qF 'anchor matched 0 lines'"
"$plant" --clean >/dev/null 2>&1 || true

exit "$fail"
