#!/usr/bin/env bash
# Fixture: gh api spanning continuation lines without header fails.
set -Eeuo pipefail
gh api --paginate \
  --jq '.items[]' \
  /repos/foo/bar/releases
