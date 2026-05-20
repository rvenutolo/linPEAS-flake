#!/usr/bin/env bash
# Fixture: gh api with explicit version header passes.
set -Eeuo pipefail
gh api --header 'X-GitHub-Api-Version: 2022-11-28' /repos/foo/bar
curl --silent --header 'X-GitHub-Api-Version: 2022-11-28' \
  https://api.github.com/repos/foo/bar
