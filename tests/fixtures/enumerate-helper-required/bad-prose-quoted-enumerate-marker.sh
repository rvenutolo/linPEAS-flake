#!/usr/bin/env bash
# tests/fixtures/enumerate-helper-required/bad-prose-quoted-enumerate-marker.sh
#
# A producer outside the helper whose comment block quotes the producer
# marker without opening a comment with it.
set -Eeuo pipefail

# A producer that must run outside the helper would need an inline
# `# enumerate-exempt: <rationale>` marker, which this one does not
# carry.
git ls-files -- 'scripts/*.sh'
