#!/usr/bin/env bash
# Fixture: raw api.github.com request missing version header.
set -Eeuo pipefail
curl --silent https://api.github.com/repos/foo/bar
