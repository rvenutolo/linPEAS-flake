#!/usr/bin/env bash
# scripts/check-gadget.sh
#
# @description Fixture subject: reads a gadget payload via
# GADGET_JSON_OVERRIDE. Carries no exit-2 shape gate at all — its paired
# harness's only scenario asserts exit 0, with a message that merely
# contains the digit 2 and the word "malformed" as prose. Exists to
# prove the scenario matcher cannot be fooled by that shape.
set -Eeuo pipefail
IFS=$'\n\t'

payload="${GADGET_JSON_OVERRIDE:?GADGET_JSON_OVERRIDE is required}"
printf '%s\n' "${payload}"
