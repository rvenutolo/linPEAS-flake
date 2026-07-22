# Verifying the image

```bash
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/example/linpeas:latest
```
