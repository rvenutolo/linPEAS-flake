#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

printf 'a\n' |
  grep --quiet a

# A backslash after the pipe, kept inside heredoc text so the formatter
# leaves it in place: the matcher reads text, not syntax.
cat <<'BODY'
printf 'b\n' | \
  grep --quiet b
BODY
