#!/usr/bin/env bash
set -Eeuo pipefail
nix run nixpkgs#cosign -- sign foo
