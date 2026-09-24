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

# Refuse a manifest that cannot be scored as written. Every seed needs an id, a
# string sentinel (jq prints a null one as the text "null", which the report
# would then be searched for) and a non-negative integer tolerance; every
# location a non-empty, tab-free path (a location is passed as "file<TAB>line")
# and a positive integer line. Anything else would die mid-table, drop seeds
# from the total, or score a false hit.
bad="$(jq -r 'def int: type == "number" and . == floor;
  if type != "array" or length == 0 then "no seeds"
  else [.[] | . as $s | ($s.id // "?") as $id
    | (if ($s.id | type) == "string" and $s.id != "" then empty else "a seed with no id" end),
      (if ($s.sentinel | type) == "string" then empty else "\($id): sentinel" end),
      (if ($s.line_tol | int) and $s.line_tol >= 0 then empty else "\($id): line_tol" end),
      (if (($s.also // []) | type) != "array" then "\($id): also"
        else ([{file: $s.file, line: $s.line}] + ($s.also // []))[]
          | select(type != "object" or (.file | type) != "string" or .file == ""
            or (.file | test("[\t\n\r]")) or ((.line | int) and .line >= 1 | not))
          | "\($id): location" end)]
    | unique | join(", ") end' "$manifest")" || {
  echo "malformed manifest $manifest: not a JSON array of seeds" >&2
  exit 1
}
[ -z "$bad" ] || {
  echo "malformed manifest $manifest: $bad" >&2
  exit 1
}

# Return 0 if a seed is detected in a single report: its sentinel appears
# anywhere, or the report cites any of the seed's locations within tolerance.
# Locations arrive as "file<TAB>line" arguments after the report — the primary
# one first, then any "also" location of a seed that spans two files.
# A citation names the whole path, optionally written with a leading ./: it
# must not follow another path character, so a longer path that merely ends
# in the seed's path is a different file,
# and the path's regex metacharacters are escaped. A cited range "file:a-b"
# hits when it comes within tolerance of the seed's line.
detected() {
  local tol="$1" sentinel="$2" report="$3" loc file line re lo hi
  shift 3
  if [ -n "$sentinel" ] && grep -qF -- "$sentinel" "$report"; then return 0; fi
  for loc in "$@"; do
    file="${loc%%$'\t'*}"
    line="${loc#*$'\t'}"
    re="$(printf '%s' "$file" | sed 's/[][\\.*^$+?(){}|]/\\&/g')"
    while IFS=- read -r lo hi; do
      lo=$((10#$lo))
      hi=$((10#${hi:-$lo}))
      [ "$((lo - tol))" -le "$line" ] && [ "$line" -le "$((hi + tol))" ] && return 0
    done < <(grep -oE -- "(^|[^A-Za-z0-9_./-])(\./)?$re:[0-9]+(-[0-9]+)?" "$report" 2>/dev/null |
      sed 's/.*://')
  done
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
  tol="$(jq -r '.line_tol | floor' <<<"$seed")"
  sentinel="$(jq -r '.sentinel' <<<"$seed")"
  mapfile -t locs < <(jq -r '([{file, line}] + (.also // []))[] | "\(.file)\t\(.line | floor)"' <<<"$seed")

  marks=""
  hits=0
  for r in "${reports[@]}"; do
    if detected "$tol" "$sentinel" "$r" "${locs[@]}"; then
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
