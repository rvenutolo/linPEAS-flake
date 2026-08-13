# A sourced library setting its own shell options, which overrides
# whatever the caller chose for the shell they share.
# shellcheck shell=bash

set -Eeuo pipefail

function joined() {
  printf '%s\n' "$*"
}
