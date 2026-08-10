#!/usr/bin/env bash
# Fixture: verify-attestation with no identity pin.
cosign verify-attestation --type slsaprovenance ghcr.io/rvenutolo/linpeas:latest
