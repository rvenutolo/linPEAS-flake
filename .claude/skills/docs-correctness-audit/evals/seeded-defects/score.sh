#!/usr/bin/env bash
# Score docs-correctness-audit reports against the planted seed manifest.
# Usage: score.sh <report.md> [<report.md> ...]
# Reads $SEEDED_RESULTS_DIR/manifest-resolved.json (default: ./results).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
results="${SEEDED_RESULTS_DIR:-$here/results}"
manifest="$results/manifest-resolved.json"
[ -f "$manifest" ] || {
  echo "no manifest at $manifest (run plant.sh first)" >&2
  exit 1
}
[ "$#" -ge 1 ] || {
  echo "usage: score.sh <report.md> ..." >&2
  exit 1
}

reports=("$@")
n="${#reports[@]}"

# Return 0 if a seed is detected in a single report.
detected() {
  local file="$1" line="$2" tol="$3" sentinel="$4" report="$5" ln d
  if [ -n "$sentinel" ] && grep -qF -- "$sentinel" "$report"; then return 0; fi
  while read -r ln; do
    d=$((ln - line))
    d=${d#-}
    [ "$d" -le "$tol" ] && return 0
  done < <(grep -oE -- "${file//./\\.}:[0-9]+" "$report" 2>/dev/null | sed 's/.*://')
  return 1
}

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
report_md="$results/recall-$stamp.md"
mkdir -p "$results"
base_sha="$(git -C "$here" rev-parse --short HEAD 2>/dev/null || echo unknown)"

total_hits=0
total_cells=0
rows=""
while IFS= read -r seed; do
  id="$(jq -r '.id' <<<"$seed")"
  cat="$(jq -r '.category' <<<"$seed")"
  file="$(jq -r '.file' <<<"$seed")"
  line="$(jq -r '.line' <<<"$seed")"
  tol="$(jq -r '.line_tol' <<<"$seed")"
  sentinel="$(jq -r '.sentinel' <<<"$seed")"

  marks=""
  hits=0
  for r in "${reports[@]}"; do
    if detected "$file" "$line" "$tol" "$sentinel" "$r"; then
      marks+="✓ "
      hits=$((hits + 1))
    else
      marks+="✗ "
    fi
  done
  flaky=""
  [ "$hits" -gt 0 ] && [ "$hits" -lt "$n" ] && flaky="FLAKY"
  rows+="| $cat | $id | $hits/$n | ${marks% } | $flaky |"$'\n'
  total_hits=$((total_hits + hits))
  total_cells=$((total_cells + n))
done < <(jq -c '.[]' "$manifest")

pct=0
[ "$total_cells" -gt 0 ] && pct=$((100 * total_hits / total_cells))

{
  echo "# Seeded-defect recall — docs-correctness-audit"
  echo
  echo "Runs: M=$n | base: $base_sha"
  echo
  echo "| category | seed | recall | $(seq -s ' ' 1 "$n" | sed 's/[0-9]*/r&/g') | flaky |"
  echo "|----------|------|--------|$(printf '%0.s-' $(seq 1 "$((2 * n))"))|-------|"
  printf '%s' "$rows"
  echo
  echo "Overall: $total_hits/$total_cells (${pct}%)"
} | tee "$report_md"
