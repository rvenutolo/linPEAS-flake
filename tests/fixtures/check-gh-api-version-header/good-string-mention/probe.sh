#!/usr/bin/env bash
# Fixture: a diagnostic naming gh api is a string, not an invocation.
set -Eeuo pipefail
function log_err() { printf '%s\n' "$1" >&2; }
readonly THIS_REPO='owner/repo'
log_err "cannot list rulesets for ${THIS_REPO}: gh api failed"
printf 'see https://api.github.com/repos/foo/bar\n'
