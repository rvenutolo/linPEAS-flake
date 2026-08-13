# A sourced library: no shebang, no shell options of its own, and a
# directive naming the dialect that the absent shebang would otherwise
# have declared.
# shellcheck shell=bash

function joined() {
  printf '%s\n' "$*"
}
