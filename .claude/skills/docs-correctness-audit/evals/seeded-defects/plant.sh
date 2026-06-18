#!/usr/bin/env bash
# Plant one defect per category into a disposable worktree copy of the repo
# so the docs-correctness-audit skill's recall can be measured.
# Usage: plant.sh           build worktree + apply seeds
#        plant.sh --clean   remove the worktree
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
seeds="$here/seeds.json"
results="$here/results"
wt="${TMPDIR:-/tmp}/docs-audit-seeded-defects"
# Skill root is three levels up from this script's dir.
skill_dir="$(cd "$here/../.." && pwd)"
skill_name="$(basename "$skill_dir")"
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
remove_worktree # idempotent: clear any prior worktree first
# Detach so the worktree does not occupy the `main` branch ref — required when
# the primary tree itself has `main` checked out. Seeds are never committed.
git -C "$repo_root" worktree add --quiet --detach "$wt" main

# Copy the (untracked) skill into the worktree so /docs-audit is discoverable.
mkdir -p "$wt/.claude/skills"
cp -r "$skill_dir" "$wt/.claude/skills/$skill_name"
[ -f "$wt/.claude/skills/$skill_name/SKILL.md" ] || {
  echo "skill copy failed" >&2
  exit 1
}

resolved="[]"
while IFS= read -r seed; do
  id="$(jq -r '.id' <<<"$seed")"
  file="$(jq -r '.file' <<<"$seed")"
  anchor="$(jq -r '.anchor' <<<"$seed")"
  op="$(jq -r '.op' <<<"$seed")"
  from="$(jq -r '.from' <<<"$seed")"
  payload="$(jq -r '.payload' <<<"$seed")"
  target="$wt/$file"

  n="$(grep -cF -- "$anchor" "$target" || true)"
  [ "$n" = 1 ] || {
    echo "seed '$id': anchor matched $n lines in $file (need 1)" >&2
    exit 1
  }
  aline="$(grep -nF -- "$anchor" "$target" | head -1 | cut -d: -f1)"

  case "$op" in
  insert-after)
    # Insert payload as the line after the anchor line.
    awk -v ln="$aline" -v ins="$payload" 'NR==ln{print; print ins; next} {print}' \
      "$target" >"$target.tmp" && mv "$target.tmp" "$target"
    rline=$((aline + 1))
    ;;
  replace-substr)
    grep -qF -- "$from" "$target" || {
      echo "seed '$id': from-string not found" >&2
      exit 1
    }
    awk -v ln="$aline" -v from="$from" -v to="$payload" '
        NR==ln { i=index($0,from); if(i>0){$0=substr($0,1,i-1) to substr($0,i+length(from))} }
        {print}' "$target" >"$target.tmp" && mv "$target.tmp" "$target"
    rline="$aline"
    ;;
  *)
    echo "seed '$id': unknown op '$op'" >&2
    exit 1
    ;;
  esac

  resolved="$(jq --argjson s "$seed" --argjson line "$rline" \
    '. + [{id:$s.id, category:$s.category, file:$s.file, line:$line,
            expected_severity:$s.expected_severity, sentinel:$s.sentinel,
            line_tol:$s.line_tol}]' <<<"$resolved")"
done < <(jq -c '.seeds[]' "$seeds")

printf '%s\n' "$resolved" | jq '.' >"$results/manifest-resolved.json"
printf '%s\n' "$wt" >"$results/worktree-path.txt"

# Primary tree must be untouched (tracked files).
if [ -n "$(git -C "$repo_root" status --porcelain --untracked-files=no)" ]; then
  echo "ERROR: primary tree has modified tracked files" >&2
  exit 1
fi

echo "Planted $(jq 'length' "$results/manifest-resolved.json") seeds into $wt"
echo "Next: cd $wt && claude  # then run /docs-audit M times"
