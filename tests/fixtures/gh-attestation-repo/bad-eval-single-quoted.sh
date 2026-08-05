#!/usr/bin/env bash
set -Eeuo pipefail
eval 'gh attestation verify evil.zip'
