#!/usr/bin/env bash
# Plant one defect per category into a disposable worktree copy of the repo
# so the docs-correctness-audit skill's recall can be measured.
# Usage: plant.sh           build worktree + apply seeds
#        plant.sh --clean   remove the worktree
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Env override (test-only): SEEDS_OVERRIDE points the plant at an alternate
# seed set, so the harness can drive the unresolvable-anchor path.
seeds="${SEEDS_OVERRIDE:-$here/seeds.json}"
results="$here/results"
wt="${TMPDIR:-/tmp}/docs-audit-seeded-defects"
repo_root="$(git -C "$here" rev-parse --show-toplevel)"

remove_worktree() {
  if git -C "$repo_root" worktree list --porcelain | grep -qxF "worktree $wt"; then
    git -C "$repo_root" worktree remove --force "$wt"
  fi
  rm -rf "$wt"
  git -C "$repo_root" worktree prune
}

if [ "${1:-}" = "--clean" ]; then
  remove_worktree
  echo "Removed worktree $wt"
  exit 0
fi

mkdir -p "$results"
# Planting must leave the primary tree exactly as it found it. Comparing the
# tracked-file status before and after asserts that; an absolute "tree is
# clean" test would instead refuse to run for anyone holding uncommitted
# edits, which is everyone running the harness-group runner before a push.
primary_before="$(git -C "$repo_root" status --porcelain --untracked-files=no)"
remove_worktree # idempotent: clear any prior worktree first
# Detach so the worktree does not occupy the branch ref the primary tree has
# checked out. The base is HEAD rather than a branch name because seeds anchor
# on verbatim sentences in tracked docs: resolving them against the commit
# under test is what makes a reworded anchor fail on the change that reworded
# it. Seeds are never committed.
git -C "$repo_root" worktree add --quiet --detach "$wt" HEAD

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
# edit to the worktree and append the line it landed on to $locs.
apply_edit() {
  local id="$1" edit="$2" file anchor op from payload target n aline rline multiline
  file="$(jq -r '.file' <<<"$edit")"
  anchor="$(jq -r '.anchor' <<<"$edit")"
  op="$(jq -r '.op' <<<"$edit")"
  from="$(jq -r '.from' <<<"$edit")"
  payload="$(jq -r '.payload' <<<"$edit")"
  target="$wt/$file"

  # Seed text is one line: grep -F reads a newline in the anchor as a second
  # pattern, and a payload that plants extra lines shifts text below it that
  # no recorded location accounts for. Checked in jq, since command
  # substitution would strip a trailing newline before bash could see it.
  multiline="$(jq -r '[("anchor", "from", "payload") as $k
    | select((.[$k] // "") | test("[\n\r]")) | $k] | join(" ")' <<<"$edit")"
  [ -z "$multiline" ] || {
    echo "seed '$id': $multiline holds a newline" >&2
    exit 1
  }
  [ -f "$target" ] || {
    echo "seed '$id': no file $file" >&2
    exit 1
  }
  n="$(grep -cF -- "$anchor" "$target" || true)"
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

# Locations are keyed by seed id, so a repeated id would merge two seeds.
dup="$(jq -r '[.seeds[].id] | group_by(.) | map(select(length > 1)[0]) | join(" ")' "$seeds")"
[ -z "$dup" ] || {
  echo "duplicate seed id(s): $dup" >&2
  exit 1
}

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
printf '%s\n' "$wt" >"$results/worktree-path.txt"

# Primary tree must be unchanged by planting (tracked files).
primary_after="$(git -C "$repo_root" status --porcelain --untracked-files=no)"
if [ "$primary_before" != "$primary_after" ]; then
  echo "ERROR: planting modified the primary tree" >&2
  exit 1
fi

echo "Planted $(jq 'length' "$results/manifest-resolved.json") seeds into $wt"
echo "Next: cd $wt && claude  # then run /docs-audit M times"
