#!/usr/bin/env bash
# Fixture: a scan root whose files hold no assignment at all. Nothing the
# rule inspects exists here, so a clean verdict would be indistinguishable
# from a detector that stopped reaching assignments.
set -Eeuo pipefail

printf 'this fixture assigns nothing\n'
