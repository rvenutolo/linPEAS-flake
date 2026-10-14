# scripts/lib/ascii-match.sh
#
# @description Bash regex matching whose ranges hold ASCII only, and a
# regex that matches a text with its ASCII letters in either case. Source
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

# @description Print a regex that matches the given text with each of its
# letters in either case, as a bracket of the two ASCII letters (`[aA]`),
# for a bash `[[ =~ ]]` or a `yq` `test()`. A lint uses it to select an
# action by its owner and repository however their letters are cased. A
# case-insensitive regex flag also folds letters outside ASCII (the
# Kelvin sign to `k`, the long s to `s`), and a bracket of two letters
# does not.
# @arg $1 text of lower-case ASCII letters, digits, `/`, `-` and `_`
# @stdout the regex, unanchored
# @exitcode 2 the text is empty or holds any other character
function ascii_fold_regex() {
  local -r lower='abcdefghijklmnopqrstuvwxyz' upper='ABCDEFGHIJKLMNOPQRSTUVWXYZ'
  local -r text="$1"
  local out='' char before i
  if [[ -z ${text} ]]; then
    printf 'ascii_fold_regex: the text is empty\n' >&2
    return 2
  fi
  for ((i = 0; i < ${#text}; i++)); do
    char="${text:i:1}"
    case "${char}" in
    [abcdefghijklmnopqrstuvwxyz])
      before="${lower%%"${char}"*}"
      out+="[${char}${upper:${#before}:1}]"
      ;;
    [0123456789/_-])
      out+="${char}"
      ;;
    *)
      printf 'ascii_fold_regex: %q holds a character that is not a lower-case ASCII letter, a digit, /, - or _\n' "${text}" >&2
      return 2
      ;;
    esac
  done
  printf '%s' "${out}"
}
