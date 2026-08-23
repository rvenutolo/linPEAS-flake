#!/usr/bin/env bash
# A second file carrying no guard shape at all, so this scan set is
# counted apart from every other clean scenario: the summary line is a
# clean run's whole output, and two of them that match cannot be told
# apart by the harness.
set -Eeuo pipefail
IFS=$'\n\t'

printf 'ok\n'
