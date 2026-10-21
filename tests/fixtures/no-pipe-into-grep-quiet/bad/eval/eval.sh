#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# @description Run a command string and report whether it succeeded.
# @arg $1 label  @arg $2 command string
function check() {
  if eval "$2"; then
    printf 'ok %s\n' "$1"
  fi
}

check "l" "printf a | grep -qF a"
check "m" "printf b | grep -q"
