#!/usr/bin/env bash
# A producer name copied to a variable. The command word at the use site is
# then a value rather than a literal, so nothing in one pass can say what
# command runs there.
set -Eeuo pipefail
IFS=$'\n\t'

# shellcheck disable=SC2209 # the bare word is the alias this fixture exists to exercise
finder=find
"${finder}" . -name '*.sh' -print
