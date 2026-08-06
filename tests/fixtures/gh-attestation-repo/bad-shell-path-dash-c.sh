#!/usr/bin/env bash
set -Eeuo pipefail
/bin/sh -c 'gh attestation verify evil.zip'
