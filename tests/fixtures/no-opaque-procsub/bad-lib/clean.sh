#!/usr/bin/env bash
# A clean executable beside the library below, so the scenario proves the
# scan descended rather than merely that the tree was dirty: a run that
# stops at the top level still reads this file and finds nothing.
set -Eeuo pipefail
IFS=$'\n\t'

listing="$(find . -name '*.sh')"
printf '%s\n' "${listing}"
