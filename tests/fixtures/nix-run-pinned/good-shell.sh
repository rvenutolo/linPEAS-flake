#!/usr/bin/env bash
set -Eeuo pipefail
nix shell .#cosign --command cosign verify foo
