#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

f="data.txt"
awk --source 'BEGIN { x = 1 }' "${f}"
