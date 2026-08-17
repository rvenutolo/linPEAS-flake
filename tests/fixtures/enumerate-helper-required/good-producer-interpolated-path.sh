#!/usr/bin/env bash
# A path that merely ends in a producer name, reached through
# interpolation. The word carries more than one part, so it yields no
# literal text and is not read as the command whose name it happens to
# end in.
set -Eeuo pipefail
IFS=$'\n\t'

dir=/usr/local/bin
finder_path="${dir}/find"
printf '%s\n' "${finder_path}"
