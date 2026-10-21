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

# A blank line and a comment line between a pipe and the grep it joins.
cat <<'BODY'
printf 'c\n' |

  grep --quiet c
printf 'd\n' |
  # the grep below is still this pipe's consumer
  grep --quiet d
BODY
