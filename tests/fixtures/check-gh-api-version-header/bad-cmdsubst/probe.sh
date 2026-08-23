#!/usr/bin/env bash
# Fixture: gh api inside a command substitution needs the header too.
set -Eeuo pipefail
payload="$(gh api /repos/foo/bar)"
printf '%s\n' "${payload}"
