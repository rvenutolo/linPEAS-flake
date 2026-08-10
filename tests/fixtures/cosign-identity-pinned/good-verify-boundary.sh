#!/usr/bin/env bash
# Fixture: neither line is a verify invocation; neither may be flagged.
cosign version
cosign verifyfoo ghcr.io/rvenutolo/linpeas:latest
