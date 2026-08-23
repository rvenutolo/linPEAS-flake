#!/usr/bin/env bash
# Fixture: the version header reaches gh api through a variable.
# The literal spelling never appears on the gh api line itself.
set -Eeuo pipefail
readonly GH_API_VERSION_HEADER='X-GitHub-Api-Version: 2022-11-28'
gh api --header "${GH_API_VERSION_HEADER}" /repos/foo/bar
