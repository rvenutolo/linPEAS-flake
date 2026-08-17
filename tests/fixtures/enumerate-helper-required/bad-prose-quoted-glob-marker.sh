#!/usr/bin/env bash
# tests/fixtures/enumerate-helper-required/bad-prose-quoted-glob-marker.sh
#
# A glob loop whose comment block quotes the glob marker without opening
# a comment with it. Prose describing the escape hatch is not the escape
# hatch, so this stays a hit.
set -Eeuo pipefail

# A loop whose empty match set is the normal state would need an inline
# `# glob-exempt: <rationale>` marker to pass, which this one does not
# carry.
for f in scripts/*.sh; do
  printf '%s\n' "${f}"
done
