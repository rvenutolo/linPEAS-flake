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
check "overall 6/9" "grep -qE '6/9' <<<\"\$out\""
check "recall report written" "ls \"$tmp\"/recall-*.md >/dev/null 2>&1"

exit "$fail"
