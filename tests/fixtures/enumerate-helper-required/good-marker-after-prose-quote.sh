#!/usr/bin/env bash
# tests/fixtures/enumerate-helper-required/good-marker-after-prose-quote.sh
#
# A block that names the marker in prose and then states it. The
# rationale read is the marker's own, not the sentence that mentions it,
# which is what keeps a quoted mention from supplying the reason a real
# marker is required to give.
set -Eeuo pipefail

# The escape hatch here is an inline `# glob-exempt: <rationale>` marker,
# and this site takes it:
# glob-exempt: this scratch root is empty on a clean checkout, so an
# empty match set is its normal state
for f in scripts/*.sh; do
  printf '%s\n' "${f}"
done
