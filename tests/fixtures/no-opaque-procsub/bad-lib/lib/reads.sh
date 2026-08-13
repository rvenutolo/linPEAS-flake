# A sourced library carrying the banned shape. Shared libraries decide
# what their callers report, so a scan that stops at the top level
# vouches for code it never read.
# shellcheck shell=bash

function read_names() {
  local name
  while IFS= read -r name; do
    printf '%s\n' "${name}"
  done < <(find . -name '*.sh')
}
