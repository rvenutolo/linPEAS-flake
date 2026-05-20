#!/usr/bin/env bash
# Fixture: gh api missing version header fails.
set -Eeuo pipefail
gh api /repos/foo/bar
