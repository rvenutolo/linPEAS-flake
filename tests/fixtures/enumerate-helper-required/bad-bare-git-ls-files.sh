#!/usr/bin/env bash
# The subcommand sits behind a global flag, which is how the real
# hand-rolled enumeration this rule was written against spelled it.
set -Eeuo pipefail
IFS=$'\n\t'

tracked="$(git -C "${PWD}" ls-files -- '*.md')"
printf '%s\n' "${tracked}"
