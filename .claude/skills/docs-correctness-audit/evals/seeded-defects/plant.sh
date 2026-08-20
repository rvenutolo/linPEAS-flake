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

# Primary tree must be unchanged by planting (tracked files).
primary_after="$(git -C "$repo_root" status --porcelain --untracked-files=no)"
if [ "$primary_before" != "$primary_after" ]; then
  echo "ERROR: planting modified the primary tree" >&2
  exit 1
fi

echo "Planted $(jq 'length' "$results/manifest-resolved.json") seeds into $wt"
echo "Next: cd $wt && claude  # then run /docs-audit M times"
