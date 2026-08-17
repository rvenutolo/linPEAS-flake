#!/usr/bin/env bash
# tests/fixtures/enumerate-helper-required/bad-orphan-marker-off-by-one.sh
#
# A marker separated from its site by a blank line. The block above a site
# is contiguous, so this marker reaches nothing while still reading as a
# decision someone made about the loop below it.
set -Eeuo pipefail

# glob-exempt: this scratch root is empty on a clean checkout

for f in scripts/*.sh; do
  printf '%s\n' "${f}"
done
