#!/usr/bin/env bash
# scripts/check-widget.sh
#
# @description Fixture subject: reads a widget payload via
# WIDGET_JSON_OVERRIDE, or fetches it live with `gh api`.
set -Eeuo pipefail
IFS=$'\n\t'

payload="${WIDGET_JSON_OVERRIDE:-}"
if [[ -z ${payload} ]]; then
  payload="$(gh api widgets)"
fi

printf '%s\n' "${payload}"
