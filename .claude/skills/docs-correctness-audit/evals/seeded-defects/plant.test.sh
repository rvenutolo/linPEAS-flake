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

# Derived, never a literal: a hard-coded expectation goes stale the moment a
# seed is added, and the staleness reads as a planting failure. The non-zero
# guard is load-bearing — an empty seeds.json would otherwise satisfy both
# count assertions while planting nothing at all.
seed_count="$(jq '.seeds | length' "$here/seeds.json")"
check "seeds.json is non-empty" "[ '$seed_count' -gt 0 ]"
check "worktree exists" "[ -d '$wt' ]"
check "skill present in worktree" "[ -f '$wt/.claude/skills/docs-correctness-audit/SKILL.md' ]"
check "manifest has $seed_count seeds" "[ \"\$(jq 'length' '$manifest')\" = $seed_count ]"
check "every seed has a numeric line" \
  "[ \"\$(jq '[.[] | select((.line|type)==\"number\" and .line>0)] | length' '$manifest')\" = $seed_count ]"

# Every sentinel (non-empty) must be present in the worktree at its recorded file.
while IFS=$'\t' read -r f s; do
  [ -n "$s" ] || continue
  check "sentinel '$s' planted in $f" "grep -qF -- '$s' '$wt/$f'"
done < <(jq -r '.[] | "\(.file)\t\(.sentinel)"' "$manifest")

# Every recorded line must hold the text its seed planted. Scoring matches a
# report's file:line citation against that line, so a line that drifts — a later
# seed inserting above an earlier one in the same file — silently moves the
# target a reader has to cite. An insert must read back as its payload exactly;
# a replacement must read back as its anchor with the from-string swapped. A
# seed's "also" edits are held to the same rule at their own recorded lines,
# and a seed must record exactly one location per edit it declares.
# Records are joined on \x1f, not a tab: tab is IFS whitespace, so the empty
# from-string of every insert would collapse into its neighbour.
assert_planted() {
  local seeds_file="$1" id f ln op anchor from payload actual ok
  while IFS=$'\x1f' read -r id f ln op anchor from payload; do
    actual="$(sed -n "${ln}p" "$wt/$f")"
    ok=0
    case "$op" in
    insert-after) [ "$actual" = "$payload" ] && ok=1 ;;
    replace-substr) [[ $actual == *"${anchor/"$from"/"$payload"}"* ]] && ok=1 ;;
    esac
    check "seed '$id': $f:$ln holds the planted text" "[ $ok = 1 ]"
  done < <(jq -r --slurpfile s "$seeds_file" '
    ($s[0].seeds | map({key: .id, value: .}) | from_entries) as $by
    | .[] | $by[.id] as $seed
    | ([{file, line}] + (.also // [])) as $locs
    | ([$seed] + ($seed.also // [])) as $edits
    | if ($locs | length) != ($edits | length) then
        [.id, "\($locs | length) locations for \($edits | length) edits", "0", "count"]
        | join("\u001f")
      else
        range(0; $locs | length) as $i
        | [.id, $locs[$i].file, ($locs[$i].line | tostring), $edits[$i].op,
          $edits[$i].anchor, $edits[$i].from, $edits[$i].payload]
        | join("\u001f")
      end' "$manifest")
}
assert_planted "$here/seeds.json"

# Planting edits content only. A mode change is a second defect the seed never
# declared — a script that lost its execute bit fails wherever it is run — and
# a tell in the worktree's diff besides.
mode_changes="$(git -C "$wt" diff --summary | grep -cF 'mode change' || true)"
check "planting changes no file mode" "[ '$mode_changes' = 0 ]"

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

# A seed can span two files through "also" edits. The fixture plants one seed
# whose also-edits land above its primary line in the same file and in a
# second file, then a later seed inserts above that second-file location, so
# every recorded line has to move with the inserts that follow it. A third
# inserts directly below that same location, which must not move it; a fourth
# replaces a from-string that also appears earlier on its line, outside the
# anchor, and must edit the occurrence inside the anchor.
"$plant" --clean >/dev/null 2>&1 || true
SEEDS_OVERRIDE="$here/fixtures/seeds-also.json" "$plant" >/dev/null
wt="$(cat "$results/worktree-path.txt")"
check "a two-file seed records both also locations" \
  "[ \"\$(jq '[.[] | select(.id == \"span\") | .also[]] | length' '$manifest')\" = 2 ]"
check "a single-file seed records no also key" \
  "[ \"\$(jq '[.[] | select(.id == \"later\") | has(\"also\")] | .[0]' '$manifest')\" = false ]"
assert_planted "$here/fixtures/seeds-also.json"
"$plant" --clean >/dev/null

# Each malformed seed set must fail the plant and name its fault: an also
# anchor that resolves nowhere; a from-string outside the anchor, whether on
# another line (the replacement would silently edit nothing) or beside the
# anchor on its own line (it would edit text the seed never named); a payload
# holding a newline (it would add lines no recorded location accounts for);
# an anchor that occurs twice on its line (which occurrence is meant is
# ambiguous); a seed text field that is not a string (jq prints null as text);
# and a repeated seed id (its locations would merge into the other seed's).
while IFS=$'\t' read -r fixture msg; do
  rc=0
  # shellcheck disable=SC2034 # read via check()'s eval of the assertion string below, not a direct expansion here
  out="$(SEEDS_OVERRIDE="$here/fixtures/$fixture" "$plant" 2>&1)" || rc=$?
  check "$fixture fails the plant" "[ '$rc' -ne 0 ]"
  check "$fixture names its fault" "printf '%s' \"\$out\" | grep -qF '$msg'"
  "$plant" --clean >/dev/null 2>&1 || true
done <<'EOF'
seeds-bad-also-anchor.json	anchor matched 0 lines in docs/index.md
seeds-from-off-line.json	from-string not inside the anchor
seeds-from-outside-anchor.json	from-string not inside the anchor
seeds-multiline-payload.json	holds a newline
seeds-dup-id.json	duplicate seed id(s): span
seeds-anchor-twice.json	occurs more than once on its line
seeds-null-payload.json	payload is not a string
EOF

exit "$fail"
