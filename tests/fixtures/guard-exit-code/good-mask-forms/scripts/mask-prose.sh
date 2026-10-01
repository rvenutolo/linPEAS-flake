#!/usr/bin/env bash
# Text naming the masked shape is not a declaration: a string, a trailing
# comment, and a declaration word that is an argument.
set -Eeuo pipefail
IFS=$'\n\t'

# shellcheck disable=SC2016 # the literal names the shape, never run
printf '%s\n' 'never write: local x="$(repo_toplevel)"'
x=1 # never: local y="$(repo_toplevel)"
echo export the root: "$(repo_toplevel)" "${x}"
