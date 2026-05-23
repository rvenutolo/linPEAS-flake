#!/usr/bin/env bash
set -Eeuo pipefail
cosign verify ghcr.io/rvenutolo/linpeas:latest
