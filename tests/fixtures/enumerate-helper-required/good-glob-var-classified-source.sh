#!/usr/bin/env bash
# The pattern is expanded at an array assignment that the glob rule
# already classifies, and that assignment carries the marker stating an
# empty match set is normal there. The loop below walks the resulting
# paths, so the breadth question was asked and answered at the site that
# expands the pattern; asking it again here would demand a second marker
# on a compliant loop and cost the exemption count its meaning.
set -Eeuo pipefail
IFS=$'\n\t'

root="${FIXTURES_ROOT:-tests/fixtures}"
shopt -s nullglob
# glob-exempt: a repo may legitimately hold no fixture directory at all,
# so an empty match is this array's expected state
dirs=("${root}"/*/)
shopt -u nullglob
# shellcheck disable=SC2068 # the unquoted array expansion is the shape this fixture exercises
for dir in ${dirs[@]}; do
  printf '%s\n' "${dir}"
done
