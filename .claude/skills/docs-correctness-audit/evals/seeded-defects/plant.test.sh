#!/usr/bin/env bash
# Exercises plant.sh end-to-end without running the audit.
# Assertion strings and the helpers they call run through check()'s eval:
# shellcheck disable=SC2016,SC2329
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

# Clean slate, then plant. The real repository's history is too long to
# rewrite in a harness, and CI checks it out shallow, so these plants skip the
# history rewrite and leave the seeds as edits; the rewrite is exercised on a
# small repository built further down.
"$plant" --clean >/dev/null 2>&1 || true
HISTORY_OVERRIDE=skip "$plant" >/dev/null

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
bad_out="$(HISTORY_OVERRIDE=skip SEEDS_OVERRIDE="$here/fixtures/seeds-bad-anchor.json" "$plant" 2>&1)" ||
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
HISTORY_OVERRIDE=skip SEEDS_OVERRIDE="$here/fixtures/seeds-also.json" "$plant" >/dev/null
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
# an also that is not an array of edit objects (its edits would be dropped
# while the plant exits 0); a seed id that is not a string, or a tolerance
# that is not an integer (score.sh would refuse the manifest after the fact);
# an empty seed list; and an id holding a newline (it splits its table row);
# and a repeated seed id (its locations would merge into the other seed's).
while IFS=$'\t' read -r fixture msg; do
  rc=0
  # shellcheck disable=SC2034 # read via check()'s eval of the assertion string below, not a direct expansion here
  out="$(HISTORY_OVERRIDE=skip SEEDS_OVERRIDE="$here/fixtures/$fixture" "$plant" 2>&1)" || rc=$?
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
seeds-also-string.json	also is not an array of edit objects
seeds-also-scalar-entry.json	also is not an array of edit objects
seeds-numeric-id.json	id is not a non-empty one-line string
seeds-fractional-tol.json	line_tol is not an integer
seeds-empty.json	no seeds
seeds-newline-id.json	id is not a non-empty one-line string
EOF

# The seeds are committed, not left as uncommitted edits, so `git status`,
# `git diff` and every diff the audit's priority set reads show nothing a
# reader could follow straight to them. Each seed lands in the commit that
# first holds its anchor, so the planted history must match the source one
# commit for commit — same subjects, identities, dates and touched paths —
# with blame on each seeded line naming the commit that wrote its anchor,
# and the audit-point markers must still resolve. The real repository's
# history is too long to rewrite in a harness, and CI checks it out
# shallow, so the rewrite is exercised on a small repository built here.
hist="$(mktemp -d)"
src="$hist/src"
git init --quiet --initial-branch=main "$src"
hgit() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$src" -c user.name=Seed -c user.email=seed@example.invalid "$@"; }
hcommit() {
  hgit add --all
  hgit commit --quiet --no-verify --no-gpg-sign --message "$1"
}
mkdir -p "$src/docs" "$src/scripts" "$src/.github"
# This repo's own attributes: git normalises line endings on the way into
# the object store, which a rewrite must not do to the bytes it replays.
printf '* text=auto eol=lf\n' >"$src/.gitattributes"
printf '# A\n\nAlpha anchor line.\n\nDelta v1 line.\n' >"$src/docs/a.md"
printf '#!/usr/bin/env bash\n# Beta anchor\necho x\n' >"$src/scripts/x.sh"
chmod +x "$src/scripts/x.sh"
hcommit 'add alpha'
printf 'other\n' >"$src/docs/other.md"
# c[1].md starts as a byte-for-byte copy of a.md, whose seeded version
# differs: a result cached per content alone would carry a.md's seed into
# it. Its name is a glob that also matches the unseeded c1.md beside it.
cp "$src/docs/a.md" "$src/docs/c[1].md"
printf 'sibling\n' >"$src/docs/c1.md"
# The seed set is committed too, as this repo commits seeds.json: its
# anchors and payloads name every seed, so no planted commit may keep it.
mkdir -p "$src/evals"
cp "$here/fixtures/seeds-history.json" "$src/evals/seeds.json"
hcommit 'add other'
# A seeded file's version stored with CRLF endings and holding no anchor
# must come through the rewrite byte for byte.
printf 'Before twin.\r\n' >"$src/docs/c[1].md"
hgit update-index --cacheinfo "100644,$(hgit hash-object -w --no-filters 'docs/c[1].md'),docs/c[1].md"
hgit commit --quiet --no-verify --no-gpg-sign --message 'crlf twin'
printf '# marker\nLAST_AUDIT_SHA=%s\n' "$(hgit rev-parse HEAD)" >"$src/.github/docs-audit-state"
hcommit 'record the first audit point'
printf '\nGamma late anchor.\n' >>"$src/docs/a.md"
printf '\nTwin anchor.\n' >>"$src/docs/c[1].md"
hcommit 'add gamma'
jq --indent 4 . "$here/fixtures/seeds-history.json" >"$src/evals/seeds.json"
hcommit 'reformat the seed set'
# A replacement anchor twice on its line cannot be planted, so this commit
# must go unseeded and the next, which leaves it once, must take the seed.
sed -i 's/^Delta v1 line\.$/Delta v2 line. Delta v2 line./' "$src/docs/a.md"
hcommit 'double delta'
sed -i 's/^Delta v2 line\. Delta v2 line\.$/Delta v2 line./' "$src/docs/a.md"
hcommit 'reword delta'
hgit switch --quiet --create side
printf 'b\n' >"$src/docs/b.md"
hcommit 'add b on a side branch'
hgit switch --quiet main
printf 'more\n' >>"$src/docs/other.md"
hcommit 'extend other'
hgit merge --quiet --no-ff --no-gpg-sign --message 'merge side' side
printf '# marker\nLAST_AUDIT_SHA=%s\n' "$(hgit rev-parse HEAD)" >"$src/.github/docs-audit-state"
hcommit 'record the second audit point'
printf 'tail\n' >>"$src/docs/other.md"
hcommit 'extend other again'
hgit tag v1
hgit branch --quiet --delete --force side
src_head="$(hgit rev-parse HEAD)"
# shellcheck disable=SC2034 # read via check()'s eval of the assertion string below, not a direct expansion here
src_refs_before="$(hgit for-each-ref)"

"$plant" --clean >/dev/null 2>&1 || true
hist_rc=0
REPO_OVERRIDE="$src" SEEDS_OVERRIDE="$src/evals/seeds.json" \
  "$plant" >/dev/null 2>&1 || hist_rc=$?
check "planting a full history exits 0" "[ '$hist_rc' = 0 ]"
wt="$(cat "$results/worktree-path.txt")"
pgit() { git -C "$wt" "$@"; }
assert_planted "$here/fixtures/seeds-history.json"
check "planted tree has a clean status" '[ -z "$(pgit status --porcelain --untracked-files=all)" ]'
check "planted tree is on branch main" '[ "$(pgit symbolic-ref --quiet --short HEAD)" = main ]'
check "planted repo holds main as its only ref" \
  "[ \"\$(pgit for-each-ref --format='%(refname)')\" = refs/heads/main ]"
check "planted repo has no remote" '[ -z "$(pgit remote)" ]'
check "planted branch tracks no upstream" '! pgit status | grep -qiE "origin|upstream"'
check "planted repo has no reflog entries" '[ -z "$(pgit reflog list)" ]'
check "planted repo has no ORIG_HEAD" '[ ! -e "$(pgit rev-parse --path-format=absolute --git-path ORIG_HEAD)" ]'
check "planted repo does not hold the source head" "! pgit cat-file -e '$src_head^{commit}' 2>/dev/null"
# Commit for commit: the planted log must carry the source's subjects,
# identities, dates, parent counts and touched paths. The touched paths are
# what the collector counts a doc's rewrite pressure from, so a seed that
# added a path to any commit would raise its file in the ranking.
# The seed set's own path is left out, with the blank separator lines: the
# planted history must not hold it, so a commit that touched nothing else
# lists no path at all there.
hist_shape() { git -C "$1" log --format='%s|%an|%ae|%at|%cn|%ce|%ct|%p' --name-only main |
  grep -vxF -e evals/seeds.json -e '' | awk -F'|' 'NF == 8 { $8 = split($8, p, " ") } 1'; }
check "planted history matches the source commit for commit" \
  "[ \"\$(hist_shape '$wt')\" = \"\$(hist_shape '$src')\" ]"
blame_subject() {
  pgit log -1 --format=%s "$(pgit blame --porcelain -L "$2,$2" -- "$1" | head -1 | cut -d' ' -f1)"
}
while IFS=$'\t' read -r sid sfile sline want; do
  check "seed '$sid' blames to '$want'" "[ \"\$(blame_subject '$sfile' '$sline')\" = '$want' ]"
done < <(
  jq -r '.[] | [.id, .file, .line] + (
    {early: ["add alpha"], late: ["add gamma"], reworded: ["reword delta"],
      twin: ["add gamma"]}[.id])
  | @tsv' "$manifest"
  jq -r '.[] | select(.id == "early") | .also[0]
  | ["early also", .file, .line, "add alpha"] | @tsv' "$manifest"
)
blob_at() { git -C "$1" rev-parse "$(git -C "$1" log --format=%H --grep="^$2\$" main):$3"; }
check "an unseeded CRLF version keeps its bytes" \
  "[ \"\$(blob_at '$wt' 'crlf twin' 'docs/c[1].md')\" = \"\$(blob_at '$src' 'crlf twin' 'docs/c[1].md')\" ]"
check "no planted commit holds the seed set" \
  '[ -z "$(pgit log --format= --name-only main -- evals/seeds.json)" ] && [ ! -e "$wt/evals/seeds.json" ]'
# No seed text reaches a file its edit does not name, in any commit.
while IFS=$'\t' read -r pfile payload; do
  check "'$payload' appears only in $pfile, in every commit" \
    "[ \"\$(pgit grep -l -F -e '$payload' \$(pgit rev-list main) -- | cut -d: -f2- | sort -u)\" = '$pfile' ]"
done < <(jq -r '.seeds[] | (., (.also // [])[]) | [.file, .payload] | @tsv' "$here/fixtures/seeds-history.json")
# Each audit point must still name a commit in the planted history, and the
# one standing where the source's did, or the priority set loses its base.
# Markers pair up by position: the history-shape check above already holds
# the two logs to the same order.
recorded_subjects() {
  git -C "$1" log --format=%H main -- .github/docs-audit-state | while IFS= read -r m; do
    git -C "$1" log -1 --format=%s \
      "$(git -C "$1" show "$m:.github/docs-audit-state" | sed -n 's/^LAST_AUDIT_SHA=//p')" \
      2>/dev/null || echo UNRESOLVED
  done
}
check "every audit point resolves to its source commit" \
  "[ \"\$(recorded_subjects '$wt')\" = \"\$(recorded_subjects '$src')\" ] && ! recorded_subjects '$wt' | grep -qx UNRESOLVED"
check "the source records two audit points" "[ \"\$(recorded_subjects '$src' | wc -l)\" = 2 ]"
check "planting a full history changes no file mode" \
  "[ \"\$(pgit ls-tree -r HEAD | cut -d' ' -f1 | sort | uniq -c)\" = \"\$(hgit ls-tree -r '$src_head' | grep -vF evals/seeds.json | cut -d' ' -f1 | sort | uniq -c)\" ] && [ -x '$wt/scripts/x.sh' ]"
check "planting a full history leaves the source refs alone" \
  '[ "$(hgit for-each-ref)" = "$src_refs_before" ]'
check "planting a full history leaves the source tree clean" '[ -z "$(hgit status --porcelain)" ]'
"$plant" --clean >/dev/null

# A shallow source has too little history to hide the seeds in: every one
# would land in its only commit, so planting must refuse rather than plant.
git clone --quiet --depth 1 "file://$src" "$hist/shallow"
shallow_rc=0
# shellcheck disable=SC2034 # read via check()'s eval of the assertion string below, not a direct expansion here
shallow_out="$(REPO_OVERRIDE="$hist/shallow" SEEDS_OVERRIDE="$here/fixtures/seeds-history.json" \
  "$plant" 2>&1)" || shallow_rc=$?
check "a shallow source exits 2" "[ '$shallow_rc' = 2 ]"
check "a shallow source names the cause" "printf '%s' \"\$shallow_out\" | grep -qF 'shallow'"
"$plant" --clean >/dev/null 2>&1 || true
rm -rf "$hist"

exit "$fail"
