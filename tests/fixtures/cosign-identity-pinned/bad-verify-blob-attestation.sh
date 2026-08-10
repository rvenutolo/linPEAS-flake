#!/usr/bin/env bash
# Fixture: the four-word subcommand a -blob|-attestation alternation misses.
cosign verify-blob-attestation --bundle sbom.json.sigstore sbom.json
