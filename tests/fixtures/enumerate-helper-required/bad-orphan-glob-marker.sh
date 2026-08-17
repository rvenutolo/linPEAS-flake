#!/usr/bin/env bash
# tests/fixtures/enumerate-helper-required/bad-orphan-glob-marker.sh
#
# A marker on a file that holds no scan site. A marker asserts that
# someone reasoned about a site and decided the helper is wrong there; one
# protecting nothing keeps asserting it after the code under it left.
set -Eeuo pipefail

# glob-exempt: this file runs no glob scan at all
printf 'hello\n'
