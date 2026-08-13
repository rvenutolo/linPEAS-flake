# A sourced library whose availability guard reports an absent parser
# with the code reserved for a content violation. The exit code a library
# chooses is the one its caller reports, which is why the scan has to
# reach it.
# shellcheck shell=bash

function require_parser() {
  if ! command -v shfmt >/dev/null 2>&1; then
    printf 'shfmt not found on PATH\n' >&2
    exit 1
  fi
}
