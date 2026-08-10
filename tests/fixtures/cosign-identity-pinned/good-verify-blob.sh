#!/usr/bin/env bash
# Fixture: verify-blob with both pins present.
cosign verify-blob \
  --certificate-identity 'https://github.com/rvenutolo/linPEAS-flake/.github/workflows/release-on-bump.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  --bundle linpeas-pin.json.sigstore \
  linpeas-pin.json
