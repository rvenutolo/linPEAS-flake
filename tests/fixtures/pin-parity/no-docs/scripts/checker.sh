#!/usr/bin/env bash
set -Eeuo pipefail
readonly SHAPE='^[0-9]{8}-[0-9a-f]{7,40}$'
if [[ ${1:-} =~ ${SHAPE} ]]; then
  printf 'ok\n'
fi
