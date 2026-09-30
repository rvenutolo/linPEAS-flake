#!/usr/bin/env bash
# Plant one defect per category into a disposable clone of the repo so the
# docs-correctness-audit skill's recall can be measured. The seeds are
# committed into a rewrite of the clone's whole history, each in the commit
# that first holds its anchor, so neither `git status` nor any diff the
# audit reads points a reader at them.
# Usage: plant.sh           build the planted clone
#        plant.sh --clean   remove it
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Env override (test-only): SEEDS_OVERRIDE points the plant at an alternate
# seed set, so the harness can drive the unresolvable-anchor path.
seeds="${SEEDS_OVERRIDE:-$here/seeds.json}"
results="$here/results"
wt="${TMPDIR:-/tmp}/docs-audit-seeded-defects"
# Env overrides (test-only): REPO_OVERRIDE plants from another repository, so
# the harness can rewrite a small history it built; HISTORY_OVERRIDE=skip
# leaves the seeds as uncommitted edits, for plants of this repository, whose
# history is too long to rewrite in a harness and shallow in CI.
repo_root="${REPO_OVERRIDE:-$(git -C "$here" rev-parse --show-toplevel)}"
history="${HISTORY_OVERRIDE:-rewrite}"
# The file the audit reads its audit points from. Each records a commit sha,
# which the rewrite has to carry over to that commit's rewritten sha.
audit_state='.github/docs-audit-state'

remove_worktree() {
  if git -C "$repo_root" worktree list --porcelain | grep -qxF "worktree $wt"; then
    git -C "$repo_root" worktree remove --force "$wt"
  fi
  rm -rf "$wt"
  git -C "$repo_root" worktree prune
}

# Edits apply to files under $root. With $replay set they apply to one older
# version of a file, where an anchor that does not resolve is skipped.
root="$wt"
replay=0

# Every applied edit's location, in application order: {id, file, line}. A
# seed's first entry is its primary location; any further entries are its
# "also" edits, which let one defect span two files — a claim a generator
# source and its rendered page agree on, say.
locs="[]"

# write_back <target>: replace <target> with <target>.tmp in place. Copying
# the content over the original, rather than moving the temp file onto it,
# keeps the original's mode — a planted script must stay executable.
write_back() {
  cat "$1.tmp" >"$1"
  rm -f "$1.tmp"
}

# apply_edit <id> <edit-json>: apply one {file, anchor, op, from, payload}
# edit to its file under $root and append the line it landed on to $locs.
apply_edit() {
  local id="$1" edit="$2" file anchor op from payload target n aline rline fault line rest
  file="$(jq -r '.file' <<<"$edit")"
  anchor="$(jq -r '.anchor' <<<"$edit")"
  op="$(jq -r '.op' <<<"$edit")"
  from="$(jq -r '.from' <<<"$edit")"
  payload="$(jq -r '.payload' <<<"$edit")"
  target="$root/$file"

  # Every edit field is a string (jq -r prints a null payload as the text
  # "null", which would be planted), and seed text is one line: grep -F reads
  # a newline in the anchor as a second pattern, and a payload that plants
  # extra lines shifts text below it that no recorded location accounts for.
  # Checked in jq, since command substitution would strip a trailing newline
  # before bash could see it.
  fault="$(jq -r '[("file", "anchor", "op", "from", "payload") as $k
      | select((.[$k] | type) != "string") | "\($k) is not a string"]
    + [("anchor", "from", "payload") as $k
      | select((.[$k] | type) == "string" and (.[$k] | test("[\n\r]")))
      | "\($k) holds a newline"]
    | join(", ")' <<<"$edit")"
  [ -z "$fault" ] || {
    echo "seed '$id': $fault" >&2
    exit 1
  }
  [ -f "$target" ] || {
    echo "seed '$id': no file $file" >&2
    exit 1
  }
  n="$(grep -cF -- "$anchor" "$target" || true)"
  # Replaying into an older commit, an anchor that does not resolve yet means
  # the seed belongs to a later commit: skip it here.
  if [ "$n" != 1 ] && [ "$replay" = 1 ]; then return 0; fi
  [ "$n" = 1 ] || {
    echo "seed '$id': anchor matched $n lines in $file (need 1)" >&2
    exit 1
  }
  aline="$(grep -nF -- "$anchor" "$target" | head -1 | cut -d: -f1)"

  # Seed text reaches awk through ENVIRON, never -v: -v processes backslash
  # escapes, so a regex like '\.\*' would arrive as '.*' and match nothing.
  case "$op" in
  insert-after)
    # Insert payload as the line after the anchor line.
    SEED_PAYLOAD="$payload" awk -v ln="$aline" \
      'NR==ln{print; print ENVIRON["SEED_PAYLOAD"]; next} {print}' \
      "$target" >"$target.tmp"
    write_back "$target"
    rline=$((aline + 1))
    # The insert pushes every line below the anchor down one, including any
    # an earlier edit already recorded in this file.
    locs="$(jq --arg f "$file" --argjson a "$aline" \
      'map(if .file == $f and .line > $a then .line += 1 else . end)' <<<"$locs")"
    ;;
  replace-substr)
    # The replacement edits the anchor's own text, so the from-string must be
    # inside it: elsewhere in the file the edit would be a silent no-op, and
    # beside the anchor on its line it would edit text the seed never named.
    [ -n "$from" ] && [[ $anchor == *"$from"* ]] || {
      echo "seed '$id': from-string not inside the anchor in $file" >&2
      exit 1
    }
    # The rewrite takes the anchor's first occurrence on its line, so a second
    # one would leave which text the seed means to the order of the line.
    line="$(sed -n "${aline}p" "$target")"
    rest="${line#*"$anchor"}"
    if [[ $rest == *"$anchor"* ]] && [ "$replay" = 1 ]; then return 0; fi
    [[ $rest != *"$anchor"* ]] || {
      echo "seed '$id': anchor occurs more than once on its line in $file" >&2
      exit 1
    }
    SEED_ANCHOR="$anchor" SEED_NEW="${anchor/"$from"/"$payload"}" awk -v ln="$aline" '
        NR==ln { a=ENVIRON["SEED_ANCHOR"]; i=index($0,a)
          $0=substr($0,1,i-1) ENVIRON["SEED_NEW"] substr($0,i+length(a)) }
        {print}' "$target" >"$target.tmp"
    write_back "$target"
    rline="$aline"
    ;;
  *)
    echo "seed '$id': unknown op '$op'" >&2
    exit 1
    ;;
  esac

  locs="$(jq --arg id "$id" --arg f "$file" --argjson l "$rline" \
    '. + [{id: $id, file: $f, line: $l}]' <<<"$locs")"
}

if [ "${1:-}" = "--clean" ]; then
  remove_worktree
  echo "Removed $wt"
  exit 0
fi

# --replay-index (internal): run by the history rewrite as its index filter,
# once per commit. Every seeded file in that commit's index is replaced by the
# same content with each of its edits that resolves there applied, so a seed
# enters history at the first commit holding its anchor. Results are cached
# per file version, since most commits leave the seeded files alone.
if [ "${1:-}" = "--replay-index" ]; then
  replay=1
  root="$PLANT_DIR/replay"
  mapfile -t files <"$PLANT_DIR/files"
  declare -A index_of=()
  for i in "${!files[@]}"; do index_of["${files[i]}"]=$i; done
  while IFS=$'\t' read -r -d '' meta f; do
    read -r mode blob _ <<<"$meta"
    key="$PLANT_DIR/cache/${index_of["$f"]}.$blob"
    if [ ! -f "$key" ]; then
      mkdir -p "$(dirname -- "$root/$f")"
      git cat-file blob "$blob" >"$root/$f"
      while IFS= read -r edit; do
        apply_edit replay "$edit"
      done < <(jq -c --arg f "$f" '.seeds[] | (., (.also // [])[]) | select(.file == $f)' "$seeds")
      git hash-object -w --no-filters -- "$root/$f" >"$key"
    fi
    new="$(cat "$key")"
    [ "$new" = "$blob" ] || git update-index --cacheinfo "$mode,$new,$f"
  done < <(git --literal-pathspecs ls-files --stage -z -- "${files[@]}")
  exit 0
fi

# Refuse a seed the manifest could not carry before planting anything: a
# non-string id never joins back to its recorded locations, a non-string
# sentinel or non-integer tolerance makes score.sh refuse the manifest after
# the fact, and an also that is not an array of objects would drop its edits
# while the plant exits 0. The tolerance is capped so bash arithmetic can read
# it (jq prints 1e19 in exponent form).
fault="$(jq -r 'def int: type == "number" and . == floor and . >= 0 and . <= 1e9;
  if (.seeds | type) != "array" then "seeds is not an array"
  elif (.seeds | length) == 0 then "no seeds"
  else [.seeds | to_entries[] | .key as $i | .value as $s
    | if ($s | type) != "object" then "seed #\($i): not an object"
      else (if ($s.id | type) == "string" and $s.id != "" and ($s.id | test("[\n\r]") | not)
            then "seed '"'"'\($s.id)'"'"'"
            else "seed #\($i)" end) as $who
        | (if $who != "seed #\($i)" then empty
            else "\($who): id is not a non-empty one-line string" end),
          (if ($s.sentinel | type) == "string" then empty
            else "\($who): sentinel is not a string" end),
          (if ($s.line_tol | int) then empty
            else "\($who): line_tol is not an integer from 0 to 1e9" end),
          (if ($s.also // []) | type == "array" and all(.[]; type == "object") then empty
            else "\($who): also is not an array of edit objects" end)
      end] | join("\n") end' "$seeds")" || {
  echo "$seeds is not a JSON object holding a seeds array" >&2
  exit 1
}
[ -z "$fault" ] || {
  printf '%s\n' "$fault" >&2
  exit 1
}

# Locations are keyed by seed id, so a repeated id would merge two seeds.
dup="$(jq -r '[.seeds[].id] | group_by(.) | map(select(length > 1)[0]) | join(" ")' "$seeds")"
[ -z "$dup" ] || {
  echo "duplicate seed id(s): $dup" >&2
  exit 1
}

mkdir -p "$results"
# Planting must leave the primary tree exactly as it found it. Comparing the
# tracked-file status before and after asserts that; an absolute "tree is
# clean" test would instead refuse to run for anyone holding uncommitted
# edits, which is everyone running the harness-group runner before a push.
primary_before="$(git -C "$repo_root" status --porcelain --untracked-files=no)"
remove_worktree # idempotent: clear any prior plant first
# The base is HEAD rather than a branch name because seeds anchor on verbatim
# sentences in tracked docs: resolving them against the commit under test is
# what makes a reworded anchor fail on the change that reworded it.
head="$(git -C "$repo_root" rev-parse --verify 'HEAD^{commit}')"
# A shallow history has no older commit to hide a seed in: every one would
# land in the newest commit, the first diff the audit reads.
if [ "$history" != skip ] && [ "$(git -C "$repo_root" rev-parse --is-shallow-repository)" = true ]; then
  echo "$repo_root is a shallow clone, too short to commit the seeds into;" \
    "fetch its full history (git fetch --unshallow) and plant again" >&2
  exit 2
fi
# A clone, not a worktree: a worktree shares the primary's refs, so a diff
# against its branch from inside the planted tree would show every seed. The
# clone keeps main alone, on the commit under test, with no remote, tag or
# other branch pointing back at the unseeded history.
git clone --quiet --no-hardlinks --no-checkout "$repo_root" "$wt"
wgit() { git -C "$wt" "$@"; }
wgit checkout --quiet -B main "$head"
wgit remote remove origin
while IFS= read -r ref; do
  [ "$ref" = refs/heads/main ] || wgit update-ref -d "$ref"
done < <(wgit for-each-ref --format='%(refname)')

while IFS= read -r seed; do
  id="$(jq -r '.id' <<<"$seed")"
  apply_edit "$id" "$seed"
  while IFS= read -r edit; do
    apply_edit "$id" "$edit"
  done < <(jq -c '(.also // [])[]' <<<"$seed")
done < <(jq -c '.seeds[]' "$seeds")

resolved="$(jq --argjson locs "$locs" '[.seeds[] as $s
  | ($locs | map(select(.id == $s.id))) as $l
  | {id: $s.id, category: $s.category, file: $s.file, line: $l[0].line,
    expected_severity: $s.expected_severity, sentinel: $s.sentinel,
    line_tol: $s.line_tol}
  + (if ($l | length) > 1 then {also: ($l[1:] | map({file, line}))} else {} end)]' \
  "$seeds")"

printf '%s\n' "$resolved" | jq '.' >"$results/manifest-resolved.json"

if [ "$history" != skip ]; then
  # Commit the seeds by rewriting every commit: the index filter plants each
  # one in the first commit whose version of its file holds the anchor, so
  # the seeded line's blame names the commit that wrote its anchor and no
  # commit touches a path it did not touch before. Each audit point is
  # rewritten to its commit's new sha, which filter-branch's map gives in
  # the index filter's own shell — hence a second, sourced step.
  plant_dir="$wt/.git/plant"
  mkdir -p "$plant_dir/cache"
  jq -r '[.seeds[] | (., (.also // [])[]) | .file] | unique[]' "$seeds" >"$plant_dir/files"
  cat >"$plant_dir/audit-point.sh" <<'FILTER'
plant_old="$(git cat-file blob ":$PLANT_AUDIT_STATE" 2>/dev/null | sed -n 's/^LAST_AUDIT_SHA=//p' | head -n 1)"
if [ -n "$plant_old" ] && git cat-file -e "$plant_old^{commit}" 2>/dev/null; then
  plant_new="$(map "$plant_old")" &&
    git cat-file blob ":$PLANT_AUDIT_STATE" |
    sed "s/^LAST_AUDIT_SHA=$plant_old\$/LAST_AUDIT_SHA=$plant_new/" >"$PLANT_DIR/state" &&
    git update-index --cacheinfo \
      "$(git ls-files --stage -- ":(literal)$PLANT_AUDIT_STATE" | cut -d' ' -f1),$(git hash-object -w --no-filters "$PLANT_DIR/state"),$PLANT_AUDIT_STATE"
fi
FILTER
  wgit reset --quiet --hard
  # BASH_ENV would source a profile into every per-commit filter process.
  if ! (
    unset BASH_ENV
    export PLANT_DIR="$plant_dir" PLANT_AUDIT_STATE="$audit_state" SEEDS_OVERRIDE="$seeds"
    export FILTER_BRANCH_SQUELCH_WARNING=1 PLANT_SELF="$here/plant.sh"
    # shellcheck disable=SC2016 # filter-branch evals the filter; it expands there
    wgit filter-branch -d "$wt/.git/plant-rewrite" \
      --index-filter '"$PLANT_SELF" --replay-index && . "$PLANT_DIR/audit-point.sh"' -- main
  ) >"$wt/.git/plant-rewrite.log" 2>&1; then
    tail -n 20 "$wt/.git/plant-rewrite.log" >&2
    echo "ERROR: rewriting the history to commit the seeds failed" >&2
    exit 1
  fi
  rm -rf "$plant_dir" "$wt/.git/plant-rewrite.log"
  wgit update-ref -d refs/original/refs/heads/main
  # Nothing may still reach the unseeded commits: the reflogs go, so gc drops
  # the originals from the object store. ORIG_HEAD goes too, since the reset
  # before the rewrite left it naming the unseeded head.
  rm -rf "$wt/.git/logs" "$wt/.git/ORIG_HEAD"
  wgit gc --quiet --prune=now
fi
printf '%s\n' "$wt" >"$results/worktree-path.txt"

# Primary tree must be unchanged by planting (tracked files).
primary_after="$(git -C "$repo_root" status --porcelain --untracked-files=no)"
if [ "$primary_before" != "$primary_after" ]; then
  echo "ERROR: planting modified the primary tree" >&2
  exit 1
fi

echo "Planted $(jq 'length' "$results/manifest-resolved.json") seeds into $wt"
echo "Next: cd $wt && claude  # then run /docs-audit M times"
