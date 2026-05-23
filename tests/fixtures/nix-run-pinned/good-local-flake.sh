#!/usr/bin/env bash
set -Eeuo pipefail
nix run .#cosign -- version
