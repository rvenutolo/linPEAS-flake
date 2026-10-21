#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

printf 'a\n' |& grep -q a
