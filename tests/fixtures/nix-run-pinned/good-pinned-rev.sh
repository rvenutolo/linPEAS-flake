#!/usr/bin/env bash
set -Eeuo pipefail
nix run nixpkgs/abc123def456abc123def456abc123def456abcd#cosign -- version
