#!/usr/bin/env bash
# tests/fixtures/enumerate-helper-required/good-marker-after-prose-quote.sh
#
# A block that names the marker in prose, ending the sentence on the
# word itself, and then states the marker for real on the next comment
# line. The rationale read is the marker's own, not the sentence that
# happens to end on the same word, which is what keeps a prose mention
# from supplying — or corrupting — the reason a real marker gives.
set -Eeuo pipefail

# the escape hatch here is spelled glob-exempt:
# glob-exempt: this scratch root is empty on a clean checkout, so an
# empty match set is its normal state
for f in scripts/*.sh; do
  printf '%s\n' "${f}"
done
