#!/usr/bin/env bash
# The only metacharacters here arrive inside a parameter expansion, where
# they are a trim pattern rather than a filesystem glob. A source walk
# that recursed into an expansion would read every line of string surgery
# in the tree as a glob source, and the unquoted reads below would become
# violations on values that can hold no pattern.
#
# Both levels an expansion can sit at are covered, because the source
# walk reads a word and a double-quoted string by separate arms and each
# has to stop at the expansion on its own: trimmed holds the expansion
# nested inside a double-quoted word, and bare is a whole assignment word
# that is nothing but the expansion.
set -Eeuo pipefail
IFS=$'\n\t'

raw="${COMMENT_TEXT:-  spaced  }"
trimmed="${raw#"${raw%%[![:space:]]*}"}"
bare=${raw%%[![:space:]]*}
matched=()
glob_into matched 'shell sources' 'scripts/*.sh'
for word in ${trimmed}; do
  printf '%s\n' "${word}"
done
for token in ${bare}; do
  printf '%s\n' "${token}"
done
printf '%s\n' "${matched[@]}"
