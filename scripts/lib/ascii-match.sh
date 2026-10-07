# scripts/lib/ascii-match.sh
#
# @description Bash regex matching whose ranges hold ASCII only. Source
# after `set -Eeuo pipefail`.
# shellcheck shell=bash

# @description Match text against a bash `[[ =~ ]]` regex under
# `C.UTF-8`, leaving `BASH_REMATCH` as the match sets it. A range such as
# `[0-9]` or `[a-z]` follows the locale's collation, so under `en_US.UTF-8`
# it also matches characters such as `٣`, `５` or `é`; under `C.UTF-8` a
# range holds ASCII only. Character classes such as `[[:space:]]` keep the
# reading `C.UTF-8` gives them, the one the CI runner gives them too. The
# locale is local to the call, so the caller's messages and tools keep
# theirs.
# @arg $1 text
# @arg $2 regex
# @exitcode 0 the text matches
# @exitcode 1 it does not
# @exitcode 2 the regex does not compile
function ascii_match() {
  local LC_ALL=C.UTF-8
  [[ $1 =~ $2 ]]
}
