#!/usr/bin/env bash
# A sanctioned exception whose marker line ends in a trailing
# backslash: `shfmt --to-json` embeds that backslash and the newline
# terminating the comment straight into the comment node's own Text
# field, rather than treating the line as continued into the next
# comment. This lint's comment record for that line therefore carries
# a literal embedded newline, and the exemption still has to be
# recognized despite it.
set -Eeuo pipefail
IFS=$'\n\t'

shopt -s nullglob
# glob-exempt: a leftover scratch file is normally absent \
for stray in ./.probe-scratch-*.md; do
  rm --force -- "${stray}"
done
