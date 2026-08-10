#!/usr/bin/env bash
set -Eeuo pipefail
nix run --quiet nixpkgs#cosign -- version
