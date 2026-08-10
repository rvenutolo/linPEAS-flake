#!/usr/bin/env bash
# Fixture: verify-blob with no identity pin at all.
cosign verify-blob --bundle linpeas-pin.json.sigstore linpeas-pin.json
