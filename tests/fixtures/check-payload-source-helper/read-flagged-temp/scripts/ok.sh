#!/usr/bin/env bash
# Fixture: a `cat --` read of a self-created temp whose command carries
# an option ahead of the `--` separator. The path operand is the word
# after `--`, not a fixed argument position, so the automatic temp
# exemption has to reach it here exactly as it does when `--` comes
# first.
set -Eeuo pipefail
IFS=$'\n\t'

err_file="$(make_temp)"
some_command 2>"${err_file}" || true
squeezed="$(cat --squeeze-blank -- "${err_file}")"
line_count="$(printf '%s\n' "${squeezed}" | wc --lines)"
printf 'stderr: %s line(s)\n' "${line_count}" >&2
