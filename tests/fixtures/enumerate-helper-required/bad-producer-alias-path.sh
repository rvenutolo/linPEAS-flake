#!/usr/bin/env bash
# The same copy written as a full path rather than a bare command name.
# The path carries a directory component ahead of the producer, so only
# the last path segment, read through basename, still names find.
set -Eeuo pipefail
IFS=$'\n\t'

finder=/usr/bin/find
"${finder}" . -name '*.sh' -print
