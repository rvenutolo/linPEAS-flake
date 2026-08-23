#!/usr/bin/env bash
# Fixture: a command word that is an expansion is named, not scored.
set -Eeuo pipefail
readonly GH_BIN='gh'
"${GH_BIN}" api /repos/foo/bar
