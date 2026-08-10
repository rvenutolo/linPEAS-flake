#!/usr/bin/env bash
set -Eeuo pipefail
nix shell nixpkgs#cosign --command cosign version
