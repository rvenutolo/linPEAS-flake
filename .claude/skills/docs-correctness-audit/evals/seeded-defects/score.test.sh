#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
score="$here/score.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if eval "$2"; then echo "ok - $1"; else
  echo "NOT ok - $1"
  fail=1
fi; }

cp "$here/fixtures/manifest-resolved.json" "$tmp/manifest-resolved.json"
# shellcheck disable=SC2034  # used inside the eval'd check() assertion strings
out="$(SEEDED_RESULTS_DIR="$tmp" "$score" \
  "$here/fixtures/all-hit.md" "$here/fixtures/all-miss.md" "$here/fixtures/mixed.md")"

check "alpha 3/3" "grep -qE 'alpha .*3/3' <<<\"\$out\""
check "beta 1/3" "grep -qE 'beta .*1/3'  <<<\"\$out\""
check "gamma 2/3" "grep -qE 'gamma .*2/3' <<<\"\$out\""
check "beta flagged FLAKY" "grep -E 'beta'  <<<\"\$out\" | grep -q FLAKY"
check "gamma flagged FLAKY" "grep -E 'gamma' <<<\"\$out\" | grep -q FLAKY"
check "alpha not flaky" "! ( grep -E 'alpha' <<<\"\$out\" | grep -q FLAKY )"
# delta spans two files: all-hit cites its also location, mixed its primary
# one, and all-miss cites the also file at an unrelated line and the primary
# file at the also line's number. Both all-miss citations must miss — a location
# matches only as its own file:line pair, within tolerance. The per-report
# marks are pinned, not just the tally: a scorer that misses all-hit and
# wrongly hits all-miss still totals 2/3.
check "delta 2/3 as hit, miss, hit" "grep -qF 'delta | 2/3 | ✓ ✗ ✓ |' <<<\"\$out\""
check "delta flagged FLAKY" "grep -E 'delta' <<<\"\$out\" | grep -q FLAKY"
check "overall 8/12" "grep -qE '8/12' <<<\"\$out\""
check "recall report written" "ls \"$tmp\"/recall-*.md >/dev/null 2>&1"

# A citation names a file only as a whole path: one that merely ends in the
# seed's path is another file, and a path's regex metacharacters are literal.
# A cited range hits when it spans the seed's line, within tolerance.
cp "$here/fixtures/manifest-citations.json" "$tmp/manifest-resolved.json"
# shellcheck disable=SC2034  # used inside the eval'd check() assertion strings
cit="$(SEEDED_RESULTS_DIR="$tmp" "$score" "$here/fixtures/citations.md")"
while IFS=$'\t' read -r id want why; do
  check "$id $want: $why" "grep -qF '| $id | $want |' <<<\"\$cit\""
done <<'EOF'
prefix	0/1	a longer path ending in the seed's path is another file
suffix	0/1	a file name ending in the seed's name is another file
meta	1/1	the seed's own path matches with its metacharacters literal
meta-false	0/1	+ in the seed's path is not a regex quantifier
range	1/1	a cited range spanning the seed's line hits
range-far	0/1	a cited range ending outside tolerance misses
wrapped	1/1	punctuation around a citation does not hide it
padded	1/1	a zero-padded line number is decimal, not octal
dotslash	1/1	a leading ./ still names the repo-relative path
meta-all	1/1	every ERE metacharacter in the seed's path is literal
float-line	1/1	a manifest line written 30.0 is line 30
near-bracket	0/1	a metacharacter in the seed's path is not a regex operator
near-brace	0/1	a metacharacter in the seed's path is not a regex operator
near-star	0/1	a metacharacter in the seed's path is not a regex operator
near-question	0/1	a metacharacter in the seed's path is not a regex operator
near-bar	0/1	a metacharacter in the seed's path is not a regex operator
near-backslash	0/1	a metacharacter in the seed's path is not a regex operator
EOF

# A manifest that cannot be scored as written must be refused by name rather
# than die mid-table, print a total that silently leaves seeds out, or score a
# false hit: a location without a positive integer line or with a tab in its
# path, a fractional tolerance, no seeds at all, a sentinel that is not a
# string (jq prints null, which the report is then searched for), an empty
# path, a seed with no id, or a number too large for bash arithmetic (jq
# prints 1e19 in exponent form).
for bad in manifest-also-no-line.json manifest-tab-path.json manifest-fractional-tol.json \
  manifest-empty.json manifest-null-sentinel.json manifest-empty-file.json manifest-no-id.json manifest-huge-tol.json; do
  cp "$here/fixtures/$bad" "$tmp/manifest-resolved.json"
  rc=0
  # shellcheck disable=SC2034  # used inside the eval'd check() assertion strings
  bad_out="$(SEEDED_RESULTS_DIR="$tmp" "$score" "$here/fixtures/all-hit.md" 2>&1)" || rc=$?
  check "$bad is refused" "[ '$rc' -ne 0 ]"
  check "$bad names the malformed manifest" "grep -qF 'malformed manifest' <<<\"\$bad_out\""
  check "$bad prints no total" "! grep -qF 'Overall:' <<<\"\$bad_out\""
done

exit "$fail"
