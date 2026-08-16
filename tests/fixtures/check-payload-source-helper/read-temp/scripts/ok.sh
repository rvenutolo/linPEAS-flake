#!/usr/bin/env bash
# Fixture: a `cat --` read of a temp file this same script created. The
# rule's automatic exemption is for exactly this shape, so no marker is
# needed here.
set -Eeuo pipefail
IFS=$'\n\t'

err_file="$(make_temp)"
some_command 2>"${err_file}" || true
cat -- "${err_file}" >&2
