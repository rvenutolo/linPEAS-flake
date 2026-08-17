#!/usr/bin/env bash
# A marker on a line carrying no guard. It excuses nothing and still reads
# as a decision about whatever sits beneath it.
set -Eeuo pipefail
IFS=$'\n\t'

# exit-code-exempt: nothing here reports a could-not-run
printf 'ok\n'
