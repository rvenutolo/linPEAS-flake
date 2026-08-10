#!/usr/bin/env bash
# Fixture: verify-blob pins identity but not the OIDC issuer.
cosign verify-blob \
  --certificate-identity 'https://github.com/rvenutolo/linPEAS-flake/.github/workflows/release-on-bump.yml@refs/heads/main' \
  --bundle linpeas-pin.json.sigstore \
  linpeas-pin.json
