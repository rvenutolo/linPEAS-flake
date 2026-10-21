#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

awk '{print}' f | grep --quiet x
