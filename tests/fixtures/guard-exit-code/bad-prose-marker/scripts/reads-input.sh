#!/usr/bin/env bash
# The exit line names the escape hatch in prose instead of opening a
# comment with it, so nothing here is actually exempted.
set -Eeuo pipefail
IFS=$'\n\t'

if [[ ! -f /nonexistent/input ]]; then
  exit 1 # a guard like this would need `# exit-code-exempt: <why>` to pass
fi
printf 'ok\n'
