#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

out="$(printf 'a\n')"
grep --quiet a <<<"${out}"
[[ -n ${out} ]] || grep -q x f
# x | grep -q y
grep -q x f
printf 'b\n' | grep -c x

# A line-final pipe joining a grep that is not quiet, directly and across
# a blank line or a comment line.
cat <<'BODY'
printf 'c\n' |
  grep -c c
printf 'd\n' |

  grep -c d
printf 'e\n' |
  # a comment between the pipe and the grep it joins
  grep -c e
BODY

# A pipe inside a trailing comment is comment text: it neither leaves the
# next line pipe-continued nor pipes into the grep it precedes.
true # x |
grep -q x f
true # x | grep -q y
