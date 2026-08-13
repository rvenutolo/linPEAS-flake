#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

f="data.txt"
awk -fprog.awk "${f}"
