#!/usr/bin/env bash
# Fixture: gh api mentions in comments do not trip the check.
# Example: gh api /repos/foo/bar
# Or: curl https://api.github.com/repos/foo/bar
set -Eeuo pipefail
echo no api call here
