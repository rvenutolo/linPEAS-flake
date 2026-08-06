#!/usr/bin/env bash
set -Eeuo pipefail
grep -Ec 'gh attestation verify SOMEARTIFACT' log
