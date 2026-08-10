#!/usr/bin/env bash
set -Eeuo pipefail
nix shell .#jq nixpkgs#cosign --command cosign version
