#!/usr/bin/env bash
# Fixture: a scanner script that names no pinned digest. It is not a pin
# file, so the provenance check neither reads nor counts it.
octoscan scan .github/workflows/wf.yml
