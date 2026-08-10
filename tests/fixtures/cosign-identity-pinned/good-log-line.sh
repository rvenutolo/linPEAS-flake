#!/usr/bin/env bash
# Fixture: a message naming the command is data, not an invocation.
asset='linpeas-pin.json'
printf 'cosign verify-blob ok: %s\n' "${asset}"
echo "cosign verify ok"
