#!/usr/bin/env bash
set -Eeuo pipefail
bash -c "gh attestation verify evil.zip"
