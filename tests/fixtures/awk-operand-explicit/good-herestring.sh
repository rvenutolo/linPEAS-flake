#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

v="one two three"
awk 'p' <<<"${v}"
